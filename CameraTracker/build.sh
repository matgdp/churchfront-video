#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product CameraTracker
bin_dir="$(swift build -c release --show-bin-path)"
app="dist/Camera Tracker.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/"
cp "$bin_dir/CameraTracker" "$app/Contents/MacOS/"
cp LICENSE NOTICE "$app/Contents/Resources/"
codesign --force --sign - "$app"
