#!/bin/sh
# Builds a universal, ad-hoc signed Wakeful.app into ./build, plus Wakeful-<version>.zip and
# its SHA-256 checksum for sharing (e.g. from a NAS).
set -eu

cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS
BIN_DIR=$(swift build -c release $ARCHS --show-bin-path)

APP=build/Wakeful.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Wakeful" "$APP/Contents/MacOS/Wakeful"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Hardened runtime blocks DYLD_INSERT_LIBRARIES-style injection into a process that can
# show an admin password prompt.
codesign --force --options runtime --sign - "$APP"
codesign --verify --deep --strict "$APP"

# ditto keeps permissions and signatures intact, unlike copying the bundle over SMB.
ZIP_NAME="Wakeful-$VERSION.zip"
ZIP="build/$ZIP_NAME"
rm -f build/Wakeful*.zip build/Wakeful*.zip.sha256
ditto -c -k --keepParent "$APP" "$ZIP"
(cd build && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")

echo "Built $APP"
echo "Share $ZIP; its checksum is in $ZIP.sha256:"
cat "$ZIP.sha256"
