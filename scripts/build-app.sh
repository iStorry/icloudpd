#!/bin/bash
# Builds "iCloud Photos Downloader.app" into ./build from the Swift package.
# Needs macOS 14+ with Xcode (or the Command Line Tools) installed.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product ICloudPhotos
BIN="$(swift build -c release --product ICloudPhotos --show-bin-path)/ICloudPhotos"

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
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will launch it locally.
codesign --force --sign - "$APP"
echo "Built: $APP"
