#!/bin/zsh
# Builds CallRecorder.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"
APP=CallRecorder.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/CallRecorder"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>CallRecorder</string>
  <key>CFBundleDisplayName</key><string>Call Recorder</string>
  <key>CFBundleIdentifier</key><string>local.callrecorder</string>
  <key>CFBundleExecutable</key><string>CallRecorder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Records your side of the call.</string>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $APP — run: open $APP"
