#!/bin/bash
# Captures every state from scripts/ux-matrix.sh with the background UX bundle (scripts/ux-run.sh), restarting it
# per fixture set. Usage: UX_SHOTS_DIR=ux/shots-x [WM_UX_DISPLAY=secondary] scripts/ux-capture-all.sh
set -uo pipefail
cd "$(dirname "$0")/.."
export UX_SHOTS_DIR="${UX_SHOTS_DIR:-ux/shots}"
current=""
scripts/ux-matrix.sh | while read -r name fixture _; do
  [ -z "$name" ] && continue
  if [ "$fixture" != "$current" ]; then
    UX_FIXTURES="$fixture" scripts/ux-run.sh >/dev/null; sleep 4; current="$fixture"
  fi
  scripts/ux-capture.sh "$name" >/dev/null 2>&1 && echo "ok   $name" || echo "FAIL $name"
done
pkill -f "Windows Manager UX.app"
