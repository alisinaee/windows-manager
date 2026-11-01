#!/bin/bash
# Usage: scripts/ux-capture.sh <state-name> ["<open query>"]   (needs the UX bundle running: scripts/ux-run.sh)
# Opens the URL with `open -g` (no focus change) on ${UX_SCHEME:-windowsmanager-ux}; the window is captured by id,
# so it works while unfocused or covered. UX_SCHEME=windowsmanager targets a normal app run with WM_UX_TEST=1.
# Without a query, the state's query comes from scripts/ux-matrix.sh. Writes $UX_SHOTS_DIR/<name>.png (default ux/shots).
# The app writes /tmp/wm-ux-ready.json ({"window": id}) when the state is on screen; the script captures that window.
set -euo pipefail
cd "$(dirname "$0")/.."
name="${1:?state name}"
query="${2:-$(scripts/ux-matrix.sh --query "$name")}"
dir="${UX_SHOTS_DIR:-ux/shots}"
mkdir -p "$dir"
ready=/tmp/wm-ux-ready.json
rm -f "$ready"
open -g "${UX_SCHEME:-windowsmanager-ux}://open?${query}"
for _ in $(seq 1 100); do [ -s "$ready" ] && break; sleep 0.2; done
[ -s "$ready" ] || { echo "app did not report the state ready for $name (is it running with WM_UX_TEST=1?)" >&2; exit 1; }
wid=$(python3 -c 'import json;print(json.load(open("'"$ready"'"))["window"])')
sleep 0.5
if [ -n "${UX_REGION:-}" ] || [ "$name" = "shortcut-recorder" ]; then
  # Popovers are separate windows: capture the screen region around the studio window instead (needs it unobscured).
  # "region" = window plus margin in global top-left coordinates (negative on displays left of / above the main one),
  # clamped to the window's screen by the app. Do not clamp to 0 here: that captured the wrong place on other displays.
  rect=$(python3 -c 'import json;d=json.load(open("'"$ready"'"));print(d.get("region") or d.get("rect",""))')
  screencapture -R "$rect" "$dir/$name.png"
else
  screencapture -l "$wid" -o "$dir/$name.png"
fi
echo "$dir/$name.png"
