#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
./scripts/build.sh
task_demo="$task_root/dist/Garmin Pulse Demo.app"
ditto "$task_root/dist/Garmin Pulse.app" "$task_demo"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier cn.wenyankong.garminpulse.demo' "$task_demo/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Garmin Pulse Demo' "$task_demo/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :GarminPulsePreview bool true' "$task_demo/Contents/Info.plist"
codesign --force --sign - --identifier cn.wenyankong.garminpulse.demo "$task_demo"
codesign --verify --deep --strict "$task_demo"
printf '%s\n' "$task_demo"
