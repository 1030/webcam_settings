# Webcam Settings for macOS

<img src="app/AppIcon.png" alt="Webcam Settings icon" width="128">

Save one UVC control preset for each physical USB camera, then reapply it from the
command line, when OBS starts, at login, or after a camera reconnects. This project
uses the macOS IOKit UVC control helper from [camtint](https://github.com/bornaware/camtint)
(MIT license, copyright 2026 CJ Ware), modified to select devices by USB location.

## Setup

Requirements: macOS 14 or later and Xcode Command Line Tools. No Homebrew or Python packages
are required.

```sh
git clone https://github.com/1030/webcam_settings.git
cd webcam_settings
./build-app.sh
open "dist/Webcam Settings.app"
```

To install, copy `dist/Webcam Settings.app` into your Applications folder,
then drag the installed app to the Dock. The local build is ad-hoc signed.

The native Mac app opens with live camera previews. Select a camera, then
optionally choose another under **Compare with**.
Click the same skin area in both previews to see each patch's average RGB and
display brightness, plus the difference between them. Use **Exposure false
colour** to compare brightness bands. These are visual guides, not calibrated
waveform or skin tone instruments. Camera access must be allowed in macOS Camera
privacy settings.

Adjust controls, give each camera a descriptive label, then select **Save preset**.
Controls take effect immediately; saving stores their current readback in
`~/.config/webcam-settings/presets.json`. To give identical cameras the same
profile, select the saved source camera, check the matching cameras under
**Sync saved profile parameters**, and select **Sync to selected cameras**.
The app applies and verifies the saved values on each target, then saves those
values under each target's own label and USB port.
If a target cannot accept or verify a value, its saved profile is left alone and
the app reports the failure. The OBS restore command does not start a preview.
The browser version remains available with `./webcam-settings ui` at
<http://127.0.0.1:8765>.

Identical webcams can advertise the same name, vendor/product ID,
and serial number. The tool therefore binds every preset to its USB location. Keep
each camera on the same hub and port. If cabling changes, identify the physical
camera again, adjust it, and save its preset at the new location. It will not
silently apply a preset to an unmatched port.

## Restore

```sh
./webcam-settings list                 # see camera port IDs and saved labels
./webcam-settings apply --wait 30      # apply all saved presets; wait for cameras
./webcam-settings obs-start            # launch OBS, then apply all presets
./webcam-settings install-agent        # restore at login, on reconnect, or OBS launch
./webcam-settings uninstall-agent      # remove the login/reconnect watcher
```

The background agent is optional. It checks USB camera presence and OBS process
starts every three seconds and reapplies on those events, not continuously. It
also starts at login. Its logs are in `~/.config/webcam-settings/`. The
`obs-start` command is an explicit alternative that waits four seconds after
opening OBS before applying presets. The installer copies the runtime into
`~/Library/Application Support/WebcamSettings` because macOS restricts login
agents from reading scripts in Documents. Re-run `install-agent` after updating
this project's code.

For an OBS startup command outside this folder, use the absolute path:

```sh
/absolute/path/to/webcam_settings/webcam-settings apply --wait 30
```

This applies the camera controls and exits; it does not need the settings page
or preview server running.

For scripting individual controls:

```sh
./webcam-settings inspect 00130000
./webcam-settings set 00130000 saturation 66
./webcam-settings save 00130000 'Desk camera'
./webcam-settings delete 00130000  # remove a preset after moving a camera
./webcam-settings sync 00110000 00130000  # copy saved values to a matching camera
```

`apply` returns a nonzero exit code and reports individual failures when a camera
is missing, a control is unsupported, or a readback differs. Auto exposure, auto
white balance, and focus modes are handled before manual values are restored.
Some cameras ignore manual values while automatic modes are enabled.

## Development

Run the preset tests without connecting any cameras:

```sh
python3 -m unittest discover -s tests -v
```

Some cameras enumerate but time out when reading controls or supplying preview
frames. Try reconnecting the camera or using another USB port/cable. Saving a
preset is refused until the camera returns readable controls.
