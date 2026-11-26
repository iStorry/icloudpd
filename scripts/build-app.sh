#!/bin/bash
# Builds "iCloud Photos Downloader.app" into ./build from the Swift package.
# Needs macOS 26+ with Xcode 26 (or the Command Line Tools) installed.
#
#   APP_VERSION=1.2.0 BUILD_NUMBER=42 scripts/build-app.sh
#
# APP_VERSION is the version people see (default 0.2.0); a suffix like "-beta.1" is kept out of the
# app's Info.plist, which only takes numbers. BUILD_NUMBER is the internal build number (default 1).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_VERSION="${APP_VERSION:-0.2.0}"
SHORT_VERSION="${APP_VERSION%%-*}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

swift build -c release --product ICloudPhotos
swift build -c release --product icloudpd-swift
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/ICloudPhotos"

APP="build/iCloud Photos Downloader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ICloudPhotos"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>iCloud Photos Downloader</string>
  <key>CFBundleDisplayName</key><string>iCloud Photos Downloader</string>
  <key>CFBundleIdentifier</key><string>local.icloudphotos.downloader</string>
  <key>CFBundleExecutable</key><string>ICloudPhotos</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Immich servers at home are usually plain http on the local network. -->
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSLocalNetworkUsageDescription</key><string>To send your photos to an Immich server on your network.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will launch it locally.
codesign --force --sign - "$APP"
mkdir -p build
cp "$BIN_DIR/icloudpd-swift" build/icloudpd-swift
echo "Built: $APP ($APP_VERSION, build $BUILD_NUMBER)"
echo "Command-line tool: build/icloudpd-swift"
