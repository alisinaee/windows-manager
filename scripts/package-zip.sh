#!/bin/sh
# Builds the app with scripts/bundle-app.sh and packs it into build/WindowsManager-<version>.zip.
# Works without an Apple developer account: the zip is signed with the local dev certificate or
# ad-hoc (see bundle-app.sh). For a notarized release, use scripts/release-notarized.sh instead.
#
#   scripts/package-zip.sh
set -e
cd "$(dirname "$0")/.."

APP_NAME="Windows Manager"
APP="build/$APP_NAME.app"
PLIST="Resources/App/Info.plist"

scripts/bundle-app.sh

if [ ! -d "$APP" ]; then
    echo "error: $APP is missing after bundle-app.sh; nothing to package" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
ZIP="build/WindowsManager-$VERSION.zip"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
SIZE="$(stat -f %z "$ZIP")"

echo
echo "Packaged: $PWD/$ZIP"
echo "sha256:   $SHA256"
echo "size:     $SIZE bytes"
