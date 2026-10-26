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
cp Resources/App/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Any other file under Resources/App (icons, assets) goes into Contents/Resources.
for f in Resources/App/*; do
    [ "$f" = "Resources/App/Info.plist" ] && continue
    [ -e "$f" ] && cp -R "$f" "$APP/Contents/Resources/"
done
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with identity: $SIGN_IDENTITY"
    codesign --force --deep -s "$SIGN_IDENTITY" "$APP"
else
    echo "Signing ad-hoc (set SIGN_IDENTITY to use a certificate)"
    codesign --force --deep -s - "$APP"
    echo
    echo "NOTE: ad-hoc signed builds may lose the Accessibility grant after each rebuild,"
    echo "because macOS (TCC) keys the grant on the code signature, and an ad-hoc signature"
    echo "changes with every build. Set SIGN_IDENTITY to a stable certificate (for example a"
    echo "self-signed 'Code Signing' certificate from Keychain Access, or your Developer ID)"
    echo "and the grant survives rebuilds."
    echo
fi

echo "Built: $(pwd)/$APP"
