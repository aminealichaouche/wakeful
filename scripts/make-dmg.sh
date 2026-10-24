#!/bin/sh
# Packages build/Wakeful.app (from build-app.sh) into build/Wakeful-<version>.dmg, with an
# Applications shortcut to drag the app onto, plus its SHA-256 checksum.
set -eu

cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP=build/Wakeful.app
DMG_NAME="Wakeful-$VERSION.dmg"
DMG="build/$DMG_NAME"

if [ ! -d "$APP" ]; then
    echo "$APP not found; run ./scripts/build-app.sh first" >&2
    exit 1
fi

STAGE=$(mktemp -d)
MOUNT=$(mktemp -d)
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rm -rf "$STAGE" "$MOUNT"' EXIT

ditto "$APP" "$STAGE/Wakeful.app"
ln -s /Applications "$STAGE/Applications"

rm -f build/Wakeful*.dmg build/Wakeful*.dmg.sha256
hdiutil create -quiet -volname "Wakeful $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"

# Check the image mounts and the app inside is still validly signed.
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
codesign --verify --deep --strict "$MOUNT/Wakeful.app"
hdiutil detach -quiet "$MOUNT"

(cd build && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")

echo "Built $DMG"
cat "$DMG.sha256"
