#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEAN_DIR="/tmp/zwiftboard-clean-build"
SRC_DIR="$CLEAN_DIR/src"
BUILD_DIR="$CLEAN_DIR/out"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$CLEAN_DIR/ZwiftBoard.app"
ZIP_PATH="$DIST_DIR/ZwiftBoard-macOS.zip"

rm -rf "$CLEAN_DIR"
mkdir -p "$SRC_DIR" "$DIST_DIR"
cp "$ROOT_DIR/Package.swift" "$SRC_DIR/"
cp -R "$ROOT_DIR/Sources" "$SRC_DIR/"

(cd "$SRC_DIR" && swift build -c release --scratch-path "$BUILD_DIR")

rm -rf "$DIST_DIR/ZwiftBoard.app" "$ZIP_PATH"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/release/ZwiftBoard" "$APP_DIR/Contents/MacOS/ZwiftBoard"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
strip -S -x "$APP_DIR/Contents/MacOS/ZwiftBoard"

cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ZwiftBoard</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.zwiftboard.mac</string>
    <key>CFBundleName</key>
    <string>ZwiftBoard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>ZwiftBoard connects to your Zwift Click controllers over Bluetooth to map button presses to MyWhoosh keyboard shortcuts.</string>
</dict>
</plist>
EOF

xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
(cd "$CLEAN_DIR" && COPYFILE_DISABLE=1 zip -r -X -q "$ZIP_PATH" ZwiftBoard.app)

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/ZwiftBoard.app
  cp -R "$APP_DIR" /Applications/ZwiftBoard.app
  codesign --verify --deep --strict /Applications/ZwiftBoard.app
  echo "Installed: /Applications/ZwiftBoard.app"
fi

rm -rf "$CLEAN_DIR"
echo "Archive:   $ZIP_PATH"
