#!/bin/sh
# Tests, builds and packages a release into "Ready to NAS":
#   Wakeful-<version>.zip      the signed app
#   Wakeful-<version>-src.zip  the source code (whitelisted files only; no build output or local state)
#   SHA256SUMS.txt             checksums for both
#   VERSION.txt                the app version
# Whatever was there before is moved to "Ready to NAS/old/<version>_<timestamp>/".
# Set SKIP_TESTS=1 to skip the test suite.
set -eu

cd "$(dirname "$0")/.."

READY="Ready to NAS"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
SOURCE_FILES="Package.swift README.md LICENSE .gitignore Resources Sources Tests scripts"
APP_ZIP="Wakeful-$VERSION.zip"
SRC_ZIP="Wakeful-$VERSION-src.zip"

if [ "${SKIP_TESTS:-0}" != "1" ]; then
    swift test
fi

./scripts/build-app.sh

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Source zip, built from an explicit list so nothing local (build folders, releases,
# editor state) can slip in.
SRC="$WORK/Wakeful-$VERSION-src"
mkdir "$SRC"
for item in $SOURCE_FILES; do
    rsync -a --exclude '.DS_Store' "$item" "$SRC/"
done
ditto -c -k --norsrc --noextattr --keepParent "$SRC" "$WORK/$SRC_ZIP"

# Check the source builds on its own before publishing it.
mkdir "$WORK/verify"
ditto -x -k "$WORK/$SRC_ZIP" "$WORK/verify"
swift build --package-path "$WORK/verify/Wakeful-$VERSION-src" -c release >/dev/null

# Check the app zip unpacks to a validly signed app.
mkdir "$WORK/verify-app"
ditto -x -k "build/$APP_ZIP" "$WORK/verify-app"
codesign --verify --deep --strict "$WORK/verify-app/Wakeful.app"

# Move the previous release aside.
mkdir -p "$READY/old"
if [ -n "$(find "$READY" -maxdepth 1 -type f ! -name '.DS_Store' -print -quit)" ]; then
    OLD_VERSION=$(cat "$READY/VERSION.txt" 2>/dev/null || echo unknown)
    OLD="$READY/old/${OLD_VERSION}_$(date +%Y-%m-%d_%H%M%S)"
    mkdir -p "$OLD"
    find "$READY" -maxdepth 1 -type f ! -name '.DS_Store' -exec mv {} "$OLD/" \;
    echo "Moved previous release to $OLD"
fi

cp "build/$APP_ZIP" "$READY/$APP_ZIP"
cp "$WORK/$SRC_ZIP" "$READY/$SRC_ZIP"
echo "$VERSION" > "$READY/VERSION.txt"
(cd "$READY" && shasum -a 256 "$APP_ZIP" "$SRC_ZIP" > SHA256SUMS.txt)

echo
echo "Released Wakeful $VERSION to \"$READY\":"
cat "$READY/SHA256SUMS.txt"
