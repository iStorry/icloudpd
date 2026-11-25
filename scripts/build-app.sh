#!/bin/bash
# Builds "iCloud Photos Downloader.app" into ./build from the Swift package.
# Needs macOS 26+ with Xcode 26 (or the Command Line Tools) installed.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product ICloudPhotos
swift build -c release --product icloudpd-swift
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/ICloudPhotos"

APP="build/iCloud Photos Downloader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ICloudPhotos"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>iCloud Photos Downloader</string>
  <key>CFBundleDisplayName</key><string>iCloud Photos Downloader</string>
  <key>CFBundleIdentifier</key><string>local.icloudphotos.downloader</string>
  <key>CFBundleExecutable</key><string>ICloudPhotos</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will launch it locally.
codesign --force --sign - "$APP"
mkdir -p build
cp "$BIN_DIR/icloudpd-swift" build/icloudpd-swift
echo "Built: $APP"
echo "Command-line tool: build/icloudpd-swift"
