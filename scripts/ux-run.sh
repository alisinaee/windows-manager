#!/bin/sh
# Starts the UX test bundle in the background, without focus, next to your own running app.
#
#   scripts/ux-run.sh                              # fixtures ux/fixtures/many, on the PA248QV display
#   UX_FIXTURES=few WM_UX_DISPLAY=largest scripts/ux-run.sh
#
# WM_UX_DISPLAY: screen name (case-insensitive, contains), 1-based screen index, "secondary" (not the menu bar screen) or "largest".
# Only a previous UX instance is stopped; your own app is never touched. Then run scripts/ux-capture.sh.
set -e
cd "$(dirname "$0")/.."
APP="$PWD/build/Windows Manager UX.app"
[ -d "$APP" ] || { echo "error: $APP not found; run scripts/bundle-app.sh && scripts/ux-bundle.sh" >&2; exit 1; }

pkill -f "Windows Manager UX.app" || true
sleep 0.5
open -g -n -a "$APP" \
    --env WM_UX_TEST=1 \
    --env "WM_PROFILES_DIR=$PWD/ux/fixtures/${UX_FIXTURES:-many}" \
    --env "WM_UX_DISPLAY=${WM_UX_DISPLAY:-PA248QV}"
echo "UX app started in the background (display: ${WM_UX_DISPLAY:-PA248QV})"
