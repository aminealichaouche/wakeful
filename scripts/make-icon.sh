#!/bin/sh
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
set -eu

cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swift scripts/make-icon.swift "$WORK/icon_1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$WORK/icon_1024.png" Resources/AppIcon.png
echo "Wrote Resources/AppIcon.icns"
