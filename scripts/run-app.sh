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
    # A "Save changes?" dialog (unsaved Studio draft) can hold the quit open. A rebuild-and-restart means the old
    # copy is stale anyway, so stop it: set KEEP_RUNNING_ON_DIALOG=1 to wait for the dialog instead.
    if pgrep -x WindowsManagerApp >/dev/null 2>&1 && [ "${KEEP_RUNNING_ON_DIALOG:-0}" != "1" ]; then
        echo "App did not quit (a dialog may be open): stopping it"
        pkill -x WindowsManagerApp || true
        sleep 1
    fi
fi

open "build/Windows Manager.app"
