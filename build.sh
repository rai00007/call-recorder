#!/bin/zsh
# Builds CallRecorder.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"
APP=CallRecorder.app
# Build in a temp dir: synced folders (e.g. iCloud Desktop) re-add xattrs that break codesign.
STAGE="$(mktemp -d)"; DEST="$PWD/$APP"; APP="$STAGE/$APP"
mkdir -p "$APP/Contents/MacOS"
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
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Records your side of the call.</string>
</dict></plist>
PLIST
xattr -cr "$APP"
# Sign with a stable identity if one exists, so macOS privacy grants (screen/mic) survive rebuilds.
# Ad-hoc signatures change on every build, which silently invalidates the grants.
ID="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/[0-9A-F]{40}/ {print $2; exit}')}"
if [[ -n "$ID" ]]; then codesign --force --sign "$ID" "$APP"; echo "Signed with $ID"
else codesign --force --sign - "$APP"; echo "Ad-hoc signed: re-grant permissions after each rebuild"; fi
rm -rf "$DEST"; ditto --norsrc --noextattr "$APP" "$DEST"; rm -rf "$STAGE"
codesign --verify --deep --strict "$DEST" && echo "Built $DEST — run: open CallRecorder.app"
