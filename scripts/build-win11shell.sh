#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$ROOT_DIR/Win11Shell"

APP_NAME="Win11Shell"
EXEC_NAME="Win11ShellApp"
BUNDLE_ID="com.hackedple.win11shell"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$BUILD_DIR/Win11Shell.iconset"
BASE_ICON_PNG="$BUILD_DIR/Win11Shell-1024.png"

echo "1. Building Win11Shell release binary..."
cd "$PKG_DIR"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/${EXEC_NAME}"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "Error: Release binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "2. Generating Win11Shell.icns..."
rm -rf "$APP_BUNDLE" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR"

"$BIN_PATH" --generate-icon "$BASE_ICON_PNG"

sips -z 16 16     "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png"      >/dev/null
sips -z 32 32     "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png"      >/dev/null
sips -z 64 64     "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png"    >/dev/null
sips -z 256 256   "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png"    >/dev/null
sips -z 512 512   "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png"    >/dev/null
cp "$BASE_ICON_PNG" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/Win11Shell.icns"

echo "3. Assembling Win11Shell.app bundle..."
cp "$BIN_PATH" "$MACOS_DIR/$EXEC_NAME"
chmod +x "$MACOS_DIR/$EXEC_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Win11 Shell</string>
    <key>CFBundleExecutable</key>
    <string>${EXEC_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>Win11Shell</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Win11 Shell</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>Win11 Shell uses Accessibility to mirror per-window menu bars, manage windows, and render right-side window controls.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Win11 Shell uses Apple Events to toggle macOS Dark Mode and trigger system power actions.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Win11 Shell displays Bluetooth status in Quick Settings and opens Bluetooth settings when requested.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Win11 Shell uses the microphone when microphone audio is enabled in Snipping Tool screen recordings.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Win11 Shell uses Screen Recording for live taskbar hover window thumbnails, Alt+Tab previews, and Snipping Tool screenshots and screen recordings.</string>
</dict>
</plist>
EOF

echo "4. Signing and verifying bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"
plutil -lint "$CONTENTS_DIR/Info.plist"
codesign --verify --deep --strict "$APP_BUNDLE"

rm -rf "$ICONSET_DIR" "$BASE_ICON_PNG"
echo "Built and verified: $APP_BUNDLE"
