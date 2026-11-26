#!/bin/bash
# Builds "iCloud Photos Downloader.app" into ./build from the Swift package.
# Needs macOS 26+ with Xcode 26 (or the Command Line Tools) installed.
#
#   APP_VERSION=1.2.0 BUILD_NUMBER=42 scripts/build-app.sh
#
# APP_VERSION is the version people see (default 0.2.0); a suffix like "-beta.1" is kept out of the
# app's Info.plist, which only takes numbers. BUILD_NUMBER is the internal build number (default 1).
#
# SIGN_IDENTITY picks the signing certificate. Left out, the app gets an ad-hoc signature, which runs
# on this Mac. For an app other people can open, use a "Developer ID Application" certificate:
#   SIGN_IDENTITY="Developer ID Application" scripts/build-app.sh && scripts/notarize.sh
# That signs the app and the command-line tool with the hardened runtime and a secure timestamp,
# which Apple's notary service requires.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_VERSION="${APP_VERSION:-0.2.0}"
SHORT_VERSION="${APP_VERSION%%-*}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

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
</dict>
</plist>
PLIST

mkdir -p build
cp "$BIN_DIR/icloudpd-swift" build/icloudpd-swift

if [ "$SIGN_IDENTITY" = "-" ]; then
  # Ad-hoc signature so macOS will launch it locally.
  codesign --force --sign - "$APP"
  codesign --force --sign - build/icloudpd-swift
else
  for item in build/icloudpd-swift "$APP"; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
  done
  codesign --verify --strict --verbose=2 "$APP"
fi
echo "Built: $APP ($APP_VERSION, build $BUILD_NUMBER, signed: $SIGN_IDENTITY)"
echo "Command-line tool: build/icloudpd-swift"
