#!/bin/sh
# Builds the release binary and assembles + signs "build/Windows Manager.app".
#
#   scripts/bundle-app.sh                         # ad-hoc signature
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/bundle-app.sh
set -e
cd "$(dirname "$0")/.."
. scripts/env.sh

APP_NAME="Windows Manager"
EXECUTABLE="WindowsManagerApp"
APP="build/$APP_NAME.app"

swift build -c release --product "$EXECUTABLE"
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
# Sparkle (update checks) is a dynamic framework. The executable links it through @rpath, and the
# build has no @executable_path/../Frameworks entry, so add it here for the bundled layout.
SPARKLE="$BIN_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE" ]; then
    echo "error: $SPARKLE not found; Sparkle must be built before bundling" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
if ! otool -l "$APP/Contents/MacOS/$EXECUTABLE" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$EXECUTABLE"
fi
cp Resources/App/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Any other file under Resources/App (icons, assets) goes into Contents/Resources.
for f in Resources/App/*; do
    [ "$f" = "Resources/App/Info.plist" ] && continue
    [ -e "$f" ] && cp -R "$f" "$APP/Contents/Resources/"
done
plutil -lint "$APP/Contents/Info.plist" >/dev/null

DEV_KC="$PWD/.signing/dev.keychain-db"
if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with identity: $SIGN_IDENTITY"
    codesign --force --deep -s "$SIGN_IDENTITY" "$APP"
elif [ -f "$DEV_KC" ]; then
    # Local dev certificate from scripts/make-dev-cert.sh: stable identity, so Accessibility survives rebuilds.
    echo "Signing with the local dev certificate (Windows Manager Dev)"
    security unlock-keychain -p "$(cat .signing/keychain-password)" "$DEV_KC"
    codesign --force --deep --keychain "$DEV_KC" -s "Windows Manager Dev" "$APP"
else
    echo "Signing ad-hoc (set SIGN_IDENTITY to use a certificate)"
    codesign --force --deep -s - "$APP"
    echo
    echo "NOTE: ad-hoc signed builds may lose the Accessibility grant after each rebuild,"
    echo "because macOS (TCC) keys the grant on the code signature, and an ad-hoc signature"
    echo "changes with every build. Run scripts/make-dev-cert.sh once (no Apple account needed), or set SIGN_IDENTITY to a stable certificate (for example a"
    echo "self-signed 'Code Signing' certificate from Keychain Access, or your Developer ID)"
    echo "and the grant survives rebuilds."
    echo
fi

echo "Built: $(pwd)/$APP"
