#!/bin/sh
# Makes "build/Windows Manager UX.app" from "build/Windows Manager.app" (run scripts/bundle-app.sh first).
# A separate bundle id and URL scheme (windowsmanager-ux), so the UX harness never touches your own running app.
#
#   scripts/bundle-app.sh && scripts/ux-bundle.sh
set -e
cd "$(dirname "$0")/.."

SRC="build/Windows Manager.app"
APP="build/Windows Manager UX.app"
PLIST="$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy

[ -d "$SRC" ] || { echo "error: $SRC not found; run scripts/bundle-app.sh first" >&2; exit 1; }
rm -rf "$APP"
cp -R "$SRC" "$APP"

"$PB" -c "Set :CFBundleIdentifier dev.windowsmanager.WindowsManager.ux" "$PLIST"
for key in CFBundleName CFBundleDisplayName; do
    "$PB" -c "Set :$key 'Windows Manager UX'" "$PLIST" 2>/dev/null || "$PB" -c "Add :$key string 'Windows Manager UX'" "$PLIST"
done
"$PB" -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 windowsmanager-ux" "$PLIST"
"$PB" -c "Set :CFBundleURLTypes:0:CFBundleURLName dev.windowsmanager.WindowsManager.ux.control" "$PLIST"
plutil -lint "$PLIST" >/dev/null

# Same signing as scripts/bundle-app.sh: SIGN_IDENTITY, else the local dev certificate, else ad-hoc.
DEV_KC="$PWD/.signing/dev.keychain-db"
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --deep -s "$SIGN_IDENTITY" "$APP"
elif [ -f "$DEV_KC" ]; then
    security unlock-keychain -p "$(cat .signing/keychain-password)" "$DEV_KC"
    codesign --force --deep --keychain "$DEV_KC" -s "Windows Manager Dev" "$APP"
else
    codesign --force --deep -s - "$APP"
fi

echo "Built: $(pwd)/$APP"
