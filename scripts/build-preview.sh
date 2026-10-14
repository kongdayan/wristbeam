#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
./scripts/build.sh
task_dist="${PULSE_OUTPUT_DIR:-$task_root/dist}"
task_dist="${task_dist:A}"
task_demo="$task_dist/WristBeam Demo.app"
ditto "$task_dist/WristBeam.app" "$task_demo"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier cn.wenyankong.wristbeam.demo' "$task_demo/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName WristBeam Demo' "$task_demo/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :GarminPulsePreview bool true' "$task_demo/Contents/Info.plist"
codesign --force --sign - --identifier cn.wenyankong.wristbeam.demo "$task_demo"
codesign --verify --deep --strict "$task_demo"
printf '%s\n' "$task_demo"
