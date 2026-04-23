# Philips Hue Tap Dial (RDM002) - SmartThings Edge Driver

This is a custom SmartThings Edge Driver for the Philips Hue Tap Dial switch. It enables full functionality of the physical buttons and the rotary dial natively within SmartThings.

## Features
- **4 Tap Buttons**: Supports `pushed` and `held` (long-press) actions for each of the four buttons.
- **Rotary Dial (Smooth Dimming)**: The driver maintains an internal "virtual" `switchLevel` (0-100%). When you physically spin the dial, the remote automatically calculates and adjusts its own brightness level.
- **Dial Turns as Buttons**: Rotating the dial also fires rapid `dialRight` and `dialLeft` button pushes, allowing you to use the dial for non-dimming routines (like turning up the volume on a speaker).

## Installation
1. Use the SmartThings CLI to package and deploy the driver to your hub:
   ```bash
   # Package the driver
   smartthings edge:drivers:package .
   
   # Assign the driver to your channel
   smartthings edge:channels:assign <DRIVER_ID> --channel <CHANNEL_ID>
   
   # Install the driver to your Hub
   smartthings edge:drivers:install <DRIVER_ID> --hub <HUB_ID> --channel <CHANNEL_ID>
   ```
2. Set your Hue Tap Dial to pairing mode (hold the button under the battery for 10 seconds until the light blinks).
3. In the SmartThings mobile app, select "Add Device" -> "Scan for nearby devices" to pair it.

## Setting Up Dimming with the Rules API
Because the standard SmartThings app UI often lacks "Sync" or "Mirror" features for Wi-Fi or Hue Bridge lights, the absolute best way to sync the rotary dial to your lights is by pushing a rule using the **SmartThings Rules API**.

I've provided an `example_mirror_rule.json` file in this repository to do exactly that.

### Instructions:
1. Find the **Device IDs** of your Hue Tap Dial and the Lights you want to control by running:
   ```bash
   smartthings devices
   ```
2. Open the `example_mirror_rule.json` file in a text editor.
3. Replace the placeholder `"YOUR_HUE_DIAL_DEVICE_ID"` with the ID of your remote.
4. Replace the placeholders `"YOUR_TARGET_LIGHT_DEVICE_ID_1"` (and any additional lights) with the IDs of the bulbs you want to dim. You can add or remove items from the `"devices"` array as needed.
5. Push the rule directly to your SmartThings account using the CLI:
   ```bash
   smartthings rules:create -j -i example_mirror_rule.json
   ```
6. Whenever you spin the dial, the remote's internal brightness will change, and the Rules API will instantly force your target lights to match that exact percentage.

*Note: Rules API routines are hidden from the SmartThings mobile app by design. You can view, manage, and delete them from the CLI using `smartthings rules`.*
