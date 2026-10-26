#!/bin/sh
# Notarized release. Run this only when an Apple Developer account exists (see docs/RELEASE.md).
#
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE="windows-manager" \
#       scripts/release-notarized.sh
#
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials windows-manager
set -e
cd "$(dirname "$0")/.."

APP_NAME="Windows Manager"
APP="build/$APP_NAME.app"
PLIST="Resources/App/Info.plist"

missing=""
[ -n "$SIGN_IDENTITY" ] || missing="$missing\n  - SIGN_IDENTITY (Developer ID Application certificate name, e.g. \"Developer ID Application: Name (TEAMID)\")"
[ -n "$NOTARY_PROFILE" ] || missing="$missing\n  - NOTARY_PROFILE (keychain profile from: xcrun notarytool store-credentials <name>)"
if [ -n "$missing" ]; then
    printf 'error: missing required environment variables:%b\n' "$missing" >&2
    printf 'Without an Apple Developer account, use scripts/package-zip.sh instead.\n' >&2
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
    echo "error: signing identity not found in the keychain: $SIGN_IDENTITY" >&2
    exit 1
fi

# Build and assemble the bundle with the identity. bundle-app.sh is not edited; this script re-signs below.
SIGN_IDENTITY="$SIGN_IDENTITY" scripts/bundle-app.sh

if [ ! -d "$APP" ]; then
    echo "error: $APP is missing after bundle-app.sh" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
ZIP="build/WindowsManager-$VERSION.zip"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"

# Hardened runtime needs this entitlement for the Apple Events used to read browser tabs.
ENT="$(mktemp -t wm-entitlements).plist"
trap 'rm -f "$ENT"' EXIT
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
PLIST

echo "Re-signing with hardened runtime (deepest first)"
# find -depth lists nested items before their parents. Sparkle 2 ships XPC services, Updater.app and
# the Autoupdate tool inside Versions/B; each must be signed before the framework, and the app last.
find "$SPARKLE_FW/Versions/B" -depth \( -name '*.xpc' -o -name '*.app' -o -name 'Autoupdate' \) -print |
while IFS= read -r item; do
    echo "  $item"
    codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$item"
done
codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$SPARKLE_FW"
codesign --force --options runtime --timestamp --entitlements "$ENT" -s "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Packaging for notarization"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to Apple notary service (waits for the result)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "Stapling the ticket to the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP"

echo "Re-packaging the stapled app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
SIZE="$(stat -f %z "$ZIP")"
echo
echo "Notarized release: $PWD/$ZIP"
echo "sha256:            $SHA256"
echo "size:              $SIZE bytes"
