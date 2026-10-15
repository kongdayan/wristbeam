#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
task_config="${PULSE_BUILD_CONFIGURATION:-release}"
task_version="${PULSE_BUILD_VERSION:-$(cat VERSION)}"
task_build="${PULSE_BUILD_NUMBER:-14}"
task_arch="${PULSE_BUILD_ARCHITECTURE:-$(uname -m)}"
task_dist="${PULSE_OUTPUT_DIR:-$task_root/dist}"
task_dist="${task_dist:A}"
[[ "$task_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid release version'; exit 1; }
[[ "$task_build" =~ '^[0-9]+$' ]] || { print -u2 'Invalid build number'; exit 1; }
[[ "$task_arch" == arm64 || "$task_arch" == x86_64 ]] || { print -u2 'Unsupported architecture'; exit 1; }
swift build -c "$task_config" --arch "$task_arch"
task_app="$task_dist/WristBeam.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp ".build/$task_arch-apple-macosx/$task_config/GarminPulse" "$task_app/Contents/MacOS/GarminPulse.next"
mv "$task_app/Contents/MacOS/GarminPulse.next" "$task_app/Contents/MacOS/GarminPulse"
cat > "$task_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>WristBeam</string>
<key>CFBundleDisplayName</key><string>WristBeam</string>
<key>CFBundleExecutable</key><string>GarminPulse</string>
<key>CFBundleIdentifier</key><string>cn.wenyankong.garminpulse</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>cn.wenyankong.garminpulse.metric</string><key>CFBundleURLSchemes</key><array><string>garminpulse</string></array><key>CFBundleTypeRole</key><string>Viewer</string></dict></array>
<key>NSBluetoothAlwaysUsageDescription</key><string>连接你的 Garmin 手表，读取实时心率、身体压力、步数和原始运动健康文件。</string>
<key>NSBluetoothPeripheralUsageDescription</key><string>连接你的 Garmin 手表并接收实时指标。</string>
<key>NSLocationUsageDescription</key><string>获取你选择的当前位置，为手表提供当地天气。</string>
<key>NSLocationWhenInUseUsageDescription</key><string>获取你选择的当前位置，为手表提供当地天气。</string>
<key>NSHumanReadableCopyright</key><string>Personal macOS companion. Not affiliated with Garmin.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $task_version" "$task_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $task_build" "$task_app/Contents/Info.plist"
mkdir -p "$task_app/Contents/Resources/Localization"
cp Sources/GarminBar/Resources/Localization/en.json "$task_app/Contents/Resources/Localization/en.json"
cp scripts/update-helper.sh "$task_app/Contents/Resources/update-helper.sh"
cp LICENSE "$task_app/Contents/Resources/LICENSE"
swift scripts/make-icon.swift "$task_dist/AppIcon.iconset"
iconutil -c icns "$task_dist/AppIcon.iconset" -o "$task_app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier cn.wenyankong.garminpulse "$task_app"
codesign --verify --deep --strict "$task_app"
plutil -lint "$task_app/Contents/Info.plist"
ditto -c -k --keepParent "$task_app" "$task_dist/WristBeam-macOS.zip"
cp "$task_dist/WristBeam-macOS.zip" "$task_dist/WristBeam-macOS-$task_arch.zip"
printf '%s\n' "$task_app"
