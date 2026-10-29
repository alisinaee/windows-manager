#!/bin/bash
# Usage: scripts/ux-capture.sh <state-name> ["<open query>"]   (needs the app running with WM_UX_TEST=1)
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
open "windowsmanager://open?${query}"
for _ in $(seq 1 100); do [ -s "$ready" ] && break; sleep 0.2; done
[ -s "$ready" ] || { echo "app did not report the state ready for $name (is it running with WM_UX_TEST=1?)" >&2; exit 1; }
wid=$(python3 -c 'import json;print(json.load(open("'"$ready"'"))["window"])')
sleep 0.5
if [ -n "${UX_REGION:-}" ] || [ "$name" = "shortcut-recorder" ]; then
  # Popovers are separate windows: capture the screen region around the studio window instead (needs it unobscured).
  rect=$(python3 -c 'import json;print(json.load(open("'"$ready"'")).get("rect",""))')
  rect=$(python3 -c 'x,y,w,h=map(int,"'"$rect"'".split(","));print("%d,%d,%d,%d"%(max(x-20,0),max(y-20,0),w+120,h+60))')
  screencapture -R "$rect" "$dir/$name.png"
else
  screencapture -l "$wid" -o "$dir/$name.png"
fi
echo "$dir/$name.png"
