#!/bin/bash
# Builds Assets/AppIcon.icns (which scripts/build-app.sh puts in the app) from a square illustration
# of a coloured icon tile on a flat, pale backdrop, by default Assets/AppIcon-source.png.
# scripts/fit-icon.swift cuts the tile out and places it on the macOS icon grid.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${1:-Assets/AppIcon-source.png}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift scripts/fit-icon.swift "$SOURCE" "$WORK/icon.png"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/icon.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$WORK/icon.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o Assets/AppIcon.icns
cp "$WORK/icon.png" Assets/AppIcon.png
echo "Wrote Assets/AppIcon.icns and Assets/AppIcon.png from $SOURCE"
