#!/bin/sh
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$DIR/dist/Webcam Settings.app"
make -C "$DIR" bin/uvcctl >/dev/null
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/Webcam Settings" "$DIR/app/WebcamSettingsApp.swift" -framework AppKit -framework AVFoundation -framework SwiftUI -framework CoreImage
cp "$DIR/app/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/app/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$DIR/webcam_settings.py" "$APP/Contents/Resources/webcam_settings.py"
cp "$DIR/bin/uvcctl" "$APP/Contents/Resources/bin/uvcctl"
codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
