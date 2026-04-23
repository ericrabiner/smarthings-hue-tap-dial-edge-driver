--[[
  Hue Tap Dial Edge Driver for SmartThings

  Handles the Philips Hue Tap Dial Switch (RDM002), a Zigbee remote with:
    - 4 tap buttons (single dot, two dots, three dots, four dots)
    - A rotating dial for brightness control

  Exposed SmartThings components:
    main      → button 1 (single dot)   — pushed / held
    button2   → button 2 (two dots)     — pushed / held
    button3   → button 3 (three dots)   — pushed / held
    button4   → button 4 (four dots)    — pushed / held
    dialRight → dial rotated clockwise  — pushed (each step/rotation)
    dialLeft  → dial rotated counter-CW — pushed (each step/rotation)

  Use these events in SmartThings Routines to dim / control lights.

  Zigbee clusters used:
    0xfc00  manuSpecificPhilips — hueNotification (0x00) → ALL button and dial events
    0x0001  Power Config        — BatteryPercentageRemaining → battery %

  ── hueNotification payload (8 bytes) ────────────────────────
    Byte 1:   button number  (1=main, 2=btn2, 3=btn3, 4=btn4, 20=dial)
    Bytes 2-4: unknown1      (UINT24, ignored)
    Byte 5:   type
                For buttons: 0=press, 1=hold, 2=press_release, 3=hold_release
                For dial:    1=step (initial), 2=rotate (continued)
    Byte 6:   unknown2       (ignored)
    Byte 7:   time           (dial rotation speed, ignored here)
    Byte 8:   direction byte (dial only: <127=right/CW, ≥127=left/CCW)

  ── Why this cluster? ─────────────────────────────────────────
    The Scenes cluster (0x0005) only delivers press events (no per-button hold).
    The Philips manufacturer cluster sends per-button press AND hold events,
    making it the only way to distinguish e.g. "button 2 held" from "button 3 held".

  ── Device configuration ──────────────────────────────────────
    For the device to send hueNotification events to the hub (instead of
    directly controlling bound Zigbee lights), it requires a one-time
    ZCL Write Attribute sent after pairing:
      Cluster:    genBasic (0x0000)
      Attribute:  0x0031  (value: 0x000b, type: BITMAP16 / 0x19)
      Mfr code:   0x100B  (Signify Netherlands B.V.)
    This is sent automatically in device_added below. If events are missing,
    re-add the device to trigger it again.
]]

local capabilities  = require "st.capabilities"
local ZigbeeDriver  = require "st.zigbee"
local zcl_clusters  = require "st.zigbee.zcl.clusters"
local data_types    = require "st.zigbee.data_types"
local device_management = require "st.zigbee.device_management"
local log           = require "log"

-- ── Cluster / command constants ──────────────────────────────

local MANU_PHILIPS_CLUSTER  = 0xfc00
local CMD_HUE_NOTIFICATION  = 0x00
local POWER_CONFIG_CLUSTER  = 0x0001
local ATTR_BATTERY_PCT      = 0x0021  -- BatteryPercentageRemaining (ZCL = 2x actual %)

-- Philips manufacturer code (Signify Netherlands B.V.)
local PHILIPS_MFR_CODE      = 0x100B

-- ── Button number → component ────────────────────────────────

local BUTTON_TO_COMPONENT = {
  [1]  = "main",
  [2]  = "button2",
  [3]  = "button3",
  [4]  = "button4",
}
local DIAL_BUTTON_ID = 20

-- ── hueNotification type byte meanings ──────────────────────
-- For tap buttons (button 1-4):
local BTN_PRESS         = 0  -- button went down
local BTN_HOLD          = 1  -- hold threshold reached
local BTN_PRESS_RELEASE = 2  -- short press confirmed (released before hold threshold)
local BTN_HOLD_RELEASE  = 3  -- released after a hold

-- ── Helpers ──────────────────────────────────────────────────

local function emit_button(device, component_id, event)
  local comp = device.profile.components[component_id]
  if comp then
    device:emit_component_event(comp, event)
  else
    log.warn("Unknown component: " .. tostring(component_id))
  end
end

-- ── Philips hueNotification handler ──────────────────────────
--
-- All button press/hold events AND dial rotation events come through
-- this single manufacturer-specific cluster command.

local function handle_hue_notification(driver, device, zb_rx)
  -- Raw payload bytes after the ZCL command header
  local bytes = zb_rx.body.zcl_body.body_bytes
  if not bytes or #bytes < 5 then
    log.warn("hueNotification: payload too short (" .. tostring(bytes and #bytes or 0) .. " bytes)")
    return
  end

  local button   = bytes:byte(1)
  local msg_type = bytes:byte(5)

  -- ── Dial ──────────────────────────────────────────────────
  if button == DIAL_BUTTON_ID then
    if #bytes < 8 then
      log.warn("hueNotification: dial payload too short")
      return
    end
    -- For dial, msg_type: 1=initial step, 2=continued rotation (fire on both)
    -- direction: byte 8 < 127 → right (CW), ≥ 127 → left (CCW)
    local dir_byte    = bytes:byte(8)
    local component_id = (dir_byte < 127) and "dialRight" or "dialLeft"
    log.info(string.format("Dial: type=%d dir_byte=%d → %s", msg_type, dir_byte, component_id))
    emit_button(device, component_id, capabilities.button.button.pushed({ state_change = true }))

    -- Manage virtual switchLevel for smooth/relative dimming
    local step_amount = 6
    local current_level = device:get_latest_state("main", capabilities.switchLevel.ID, capabilities.switchLevel.level.NAME) or 50
    local new_level = current_level

    if component_id == "dialRight" then
      new_level = math.min(100, current_level + step_amount)
    else
      new_level = math.max(0, current_level - step_amount)
    end

    if new_level ~= current_level then
      log.info(string.format("Virtual dim level: %d%%", new_level))
      device:emit_component_event(device.profile.components.main, capabilities.switchLevel.level(new_level))
    end

  -- ── Tap buttons 1-4 ────────────────────────────────────────
  else
    local component_id = BUTTON_TO_COMPONENT[button]
    if not component_id then
      log.warn("hueNotification: unknown button number " .. tostring(button))
      return
    end

    if msg_type == BTN_PRESS_RELEASE then
      -- Short press confirmed (released before hold threshold) → pushed
      log.info(string.format("Button %d short press → %s pushed", button, component_id))
      emit_button(device, component_id, capabilities.button.button.pushed({ state_change = true }))

    elseif msg_type == BTN_HOLD then
      -- Hold threshold reached → held
      log.info(string.format("Button %d hold → %s held", button, component_id))
      emit_button(device, component_id, capabilities.button.button.held({ state_change = true }))

    else
      -- BTN_PRESS (0) and BTN_HOLD_RELEASE (3) are silently ignored.
      -- Use BTN_PRESS_RELEASE for push and BTN_HOLD for hold so that a long
      -- press never fires both pushed and held.
      log.debug(string.format("Button %d type=%d (ignored)", button, msg_type))
    end
  end
end

--- Battery percentage remaining (ZCL reports 2× actual %)
local function handle_battery(driver, device, value, zb_rx)
  local pct = math.floor((value.value or 0) / 2)
  pct = math.max(0, math.min(100, pct))
  log.info("Battery: " .. pct .. "%")
  device:emit_event(capabilities.battery.battery(pct))
end

-- ── Device configuration ──────────────────────────────────────
--
-- Write genBasic attribute 0x0031 = 0x000b with Philips manufacturer code.
-- This switches the device into "event forwarding" mode so it sends
-- hueNotification commands to the hub rather than directly controlling
-- bound lights via the Scenes/Level clusters.
--
-- ZCL frame details:
--   Frame ctrl: 0x14 (global, manufacturer-specific, C→S, disable_default_rsp)
--   Mfr code:   0x0B 0x10  (0x100B little-endian)
--   Sequence:   0x00
--   Command:    0x02  (Write Attributes)
--   Payload:    0x31 0x00  (attr id 0x0031, LE)
--               0x19       (data type BITMAP16)
--               0x0B 0x00  (value 0x000b, LE)

local cluster_base = require "st.zigbee.cluster_base"

local function send_philips_configure(device)
  local ok, err = pcall(function()
    local msg = cluster_base.write_manufacturer_specific_attribute(
      device,
      0x0000, -- genBasic
      0x0031, -- attribute ID
      0x100B, -- Philips manufacturer code
      data_types.Bitmap16,
      0x000B  -- value
    )
    device:send(msg)
    log.info("Sent Philips hueNotification enable config via SDK")
  end)
  if not ok then
    log.warn("Could not send Philips configure frame: " .. tostring(err))
  end
end

local function handle_set_level(driver, device, command)
  local level = command.args.level
  device:emit_component_event(device.profile.components.main, capabilities.switchLevel.level(level))
end

-- ── Lifecycle ─────────────────────────────────────────────────

-- All components that carry the button capability (must match profile IDs)
local BUTTON_COMPONENT_IDS = { "main", "button2", "button3", "button4", "dialRight", "dialLeft" }

local function ensure_device_profile(device)
  device.log.info("Updating device profile to hue-tap-dial")
  device:try_update_metadata({
    profile = "hue-tap-dial",
    provisioning_state = "PROVISIONED",
  })
end

local function announce_button_values(device)
  local supported = { "pushed", "held" }
  for _, comp_id in ipairs(BUTTON_COMPONENT_IDS) do
    local comp = device.profile.components[comp_id]
    if comp then
      device:emit_component_event(comp,
        capabilities.button.supportedButtonValues(supported, { visibility = { displayed = false } })
      )
      device:emit_component_event(comp,
        capabilities.button.numberOfButtons({ value = 1 }, { visibility = { displayed = false } })
      )
    else
      log.warn("Component not found in profile: " .. comp_id)
    end
  end
end

local function device_added(driver, device)
  log.info("Device added: " .. device.label)
  ensure_device_profile(device)
  announce_button_values(device)
  device:emit_event(capabilities.battery.battery(100))
  device:emit_component_event(device.profile.components.main, capabilities.switchLevel.level(50))
  
  -- Explicitly bind clusters so the device sends reports to the Hub instead of broadcasting
  device:send(device_management.build_bind_request(device, MANU_PHILIPS_CLUSTER, driver.environment_info.hub_zigbee_eui))
  device:send(device_management.build_bind_request(device, 0x0000, driver.environment_info.hub_zigbee_eui))
  device:send(device_management.build_bind_request(device, 0x0001, driver.environment_info.hub_zigbee_eui))
  device:send(device_management.build_bind_request(device, 0x0006, driver.environment_info.hub_zigbee_eui))
  device:send(device_management.build_bind_request(device, 0x0008, driver.environment_info.hub_zigbee_eui))

  send_philips_configure(device)
end

local function device_init(driver, device)
  log.info("Device init: " .. device.label)
  ensure_device_profile(device)
  announce_button_values(device)

  device:send(device_management.build_bind_request(device, MANU_PHILIPS_CLUSTER, driver.environment_info.hub_zigbee_eui))
  send_philips_configure(device)

  local battery_attr = zcl_clusters.PowerConfiguration.attributes.BatteryPercentageRemaining
  device:send(battery_attr:read(device))
end

local function device_removed(driver, device)
  log.info("Device removed: " .. device.label)
end

local function device_driver_switched(driver, device)
  log.info("Driver switched: " .. device.label)
  ensure_device_profile(device)
  announce_button_values(device)
  send_philips_configure(device)
end

-- ── Driver definition ─────────────────────────────────────────

local driver = ZigbeeDriver("Hue Tap Dial", {
  supported_capabilities = {
    capabilities.button,
    capabilities.battery,
    capabilities.switchLevel,
  },

  capability_handlers = {
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = handle_set_level,
    }
  },

  zigbee_handlers = {
    cluster = {
      -- All button and dial events come through the Philips manufacturer cluster
      [MANU_PHILIPS_CLUSTER] = {
        [CMD_HUE_NOTIFICATION] = handle_hue_notification,
      },
    },
    attr = {
      [POWER_CONFIG_CLUSTER] = {
        [ATTR_BATTERY_PCT] = handle_battery,
      },
    },
  },

  lifecycle_handlers = {
    added   = device_added,
    init    = device_init,
    driverSwitched = device_driver_switched,
    removed = device_removed,
  },
})

log.info("Starting Hue Tap Dial Edge Driver")
driver:run()
