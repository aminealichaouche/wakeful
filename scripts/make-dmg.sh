#!/bin/sh
# Packages an app built by build-app.sh into a disk image with an Applications shortcut to drag
# the app onto, plus its SHA-256 checksum.
#
#   ./scripts/make-dmg.sh            build/Wakeful.app         → build/Wakeful-<version>.dmg
#   ./scripts/make-dmg.sh --offline  build/offline/Wakeful.app → build/Wakeful-<version>-offline.dmg
set -eu

cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
case "${1:-}" in
    --offline)
        APP=build/offline/Wakeful.app
        DMG_NAME="Wakeful-$VERSION-offline.dmg"
        VOLUME="Wakeful $VERSION Offline"
        ;;
    "")
        APP=build/Wakeful.app
        DMG_NAME="Wakeful-$VERSION.dmg"
        VOLUME="Wakeful $VERSION"
        ;;
    *) echo "usage: $0 [--offline]" >&2; exit 2 ;;
esac
DMG="build/$DMG_NAME"

if [ ! -d "$APP" ]; then
    echo "$APP not found; run ./scripts/build-app.sh ${1:-} first" >&2
    exit 1
fi

STAGE=$(mktemp -d)
MOUNT=$(mktemp -d)
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rm -rf "$STAGE" "$MOUNT"' EXIT

ditto "$APP" "$STAGE/Wakeful.app"
ln -s /Applications "$STAGE/Applications"

if [ "${1:-}" = --offline ]; then
    find build -maxdepth 1 -name 'Wakeful-*-offline.dmg*' -delete
else
    find build -maxdepth 1 -name 'Wakeful-*.dmg*' ! -name '*-offline.dmg*' -delete
fi
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"

# Check the image mounts and the app inside is still validly signed.
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
codesign --verify --deep --strict "$MOUNT/Wakeful.app"
hdiutil detach -quiet "$MOUNT"

(cd build && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")

echo "Built $DMG"
cat "$DMG.sha256"
