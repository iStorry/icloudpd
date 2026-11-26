#!/bin/bash
# Builds Assets/AppIcon.icns (which scripts/build-app.sh puts in the app) and Assets/AppIcon.png.
# The icon is drawn in code by scripts/draw-icon.swift: change it there and run this again.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift scripts/draw-icon.swift "$WORK/icon.png"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/icon.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$WORK/icon.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o Assets/AppIcon.icns
cp "$WORK/icon.png" Assets/AppIcon.png
echo "Wrote Assets/AppIcon.icns and Assets/AppIcon.png"
