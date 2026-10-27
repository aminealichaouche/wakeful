#!/bin/sh
# Builds a universal, ad-hoc signed Wakeful.app plus a zip and its SHA-256 checksum.
#
#   ./scripts/build-app.sh            standard edition  → build/Wakeful.app, build/Wakeful-<version>.zip
#   ./scripts/build-app.sh --offline  offline edition   → build/offline/Wakeful.app, build/Wakeful-<version>-offline.zip
#
# The offline edition is compiled with -DOFFLINE, which leaves out the update checker and every
# other network feature. This script checks the result really contains no network code.
set -eu

cd "$(dirname "$0")/.."

EDITION=standard
case "${1:-}" in
    --offline) EDITION=offline ;;
    "") ;;
    *) echo "usage: $0 [--offline]" >&2; exit 2 ;;
esac

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ARCHS="--arch arm64 --arch x86_64"
if [ "$EDITION" = offline ]; then
    FLAGS="-Xswiftc -DOFFLINE"
    SCRATCH=.build/offline
    APP_DIR=build/offline
    ZIP_NAME="Wakeful-$VERSION-offline.zip"
else
    FLAGS=""
    SCRATCH=.build
    APP_DIR=build
    ZIP_NAME="Wakeful-$VERSION.zip"
fi

swift build -c release $ARCHS $FLAGS --scratch-path "$SCRATCH"
BIN_DIR=$(swift build -c release $ARCHS $FLAGS --scratch-path "$SCRATCH" --show-bin-path)
BINARY="$BIN_DIR/Wakeful"

if [ "$EDITION" = offline ]; then
    # Fail the build if anything able to reach the network made it in.
    if strings -a "$BINARY" | grep -qiE 'github\.com|https?://'; then
        echo "error: offline build contains a web address" >&2; exit 1
    fi
    if nm -u "$BINARY" | grep -qiE 'URLSession|NSURLConnection|CFNetwork|nw_connection|_socket$|_connect$'; then
        echo "error: offline build links networking APIs" >&2; exit 1
    fi
    if nm "$BINARY" | grep -q UpdateChecker; then
        echo "error: offline build contains the update checker" >&2; exit 1
    fi
fi

APP="$APP_DIR/Wakeful.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Wakeful"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Hardened runtime blocks DYLD_INSERT_LIBRARIES-style injection into a process that can
# show an admin password prompt.
codesign --force --options runtime --sign - "$APP"
codesign --verify --deep --strict "$APP"

# ditto keeps permissions and signatures intact, unlike copying the bundle over SMB.
# Only this edition's older zips are removed.
ZIP="build/$ZIP_NAME"
if [ "$EDITION" = offline ]; then
    find build -maxdepth 1 -name 'Wakeful-*-offline.zip*' -delete
else
    find build -maxdepth 1 -name 'Wakeful-*.zip*' ! -name '*-offline.zip*' -delete
fi
ditto -c -k --keepParent "$APP" "$ZIP"
(cd build && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")

echo "Built $APP ($EDITION edition)"
echo "Share $ZIP; its checksum is in $ZIP.sha256:"
cat "$ZIP.sha256"
