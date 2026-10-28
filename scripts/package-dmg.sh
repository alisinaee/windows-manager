#!/bin/sh
# Builds the app (scripts/bundle-app.sh) and packs build/WindowsManager-<version>.dmg with an Applications link.
# Not notarized: see docs/INSTALL.md for the xattr step users need.
#
#   scripts/package-dmg.sh
set -e
cd "$(dirname "$0")/.."

APP_NAME="Windows Manager"
APP="build/$APP_NAME.app"
PLIST="Resources/App/Info.plist"

scripts/bundle-app.sh
[ -d "$APP" ] || { echo "error: $APP missing" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
DMG="build/WindowsManager-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.md "$STAGE/Install (read me).txt"

rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "DMG: $DMG"
echo "sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
