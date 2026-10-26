#!/bin/sh
# Bundles the app, quits a running copy, then opens the fresh build.
set -e
cd "$(dirname "$0")/.."

BUNDLE_ID="dev.windowsmanager.WindowsManager"

scripts/bundle-app.sh

# Quit a running copy (only if there is one, so osascript never launches the app by itself).
if pgrep -x WindowsManagerApp >/dev/null 2>&1; then
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x WindowsManagerApp >/dev/null 2>&1 || break
        sleep 0.5
    done
fi

open "build/Windows Manager.app"
