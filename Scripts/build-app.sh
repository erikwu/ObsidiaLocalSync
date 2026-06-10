#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SyncTwin"
APP_VERSION="1.0.6"
BUILD_MODE="${1:-release}"

cd "$ROOT_DIR"

swift build -c "$BUILD_MODE"

BIN_DIR="$(swift build -c "$BUILD_MODE" --show-bin-path)"
BIN_PATH="$BIN_DIR/$APP_NAME"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

mkdir -p "$MACOS_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>local.synctwin.app</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>SyncTwin 使用蓝牙作为本地设备发现和传输的备选链路。</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>SyncTwin 需要通过本地网络发现另一台已安装的电脑并进行加密同步。</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "Built $APP_DIR"
