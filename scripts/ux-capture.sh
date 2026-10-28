#!/bin/bash
# Usage: scripts/ux-capture.sh <state-name> ["<open query>"]   (needs the app running with WM_UX_TEST=1)
# Without a query, the state's query comes from scripts/ux-matrix.sh. Writes ux/shots/<name>.png.
set -euo pipefail
cd "$(dirname "$0")/.."
name="${1:?state name}"
query="${2:-$(scripts/ux-matrix.sh --query "$name")}"
mkdir -p ux/shots
open "windowsmanager://open?${query}"
sleep 1
wid=$(python3 - <<'PY'
import sys
try:
    import Quartz
except ImportError:
    sys.exit(1)
best=None
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID):
    if w.get("kCGWindowOwnerName") in ("WindowsManagerApp","Windows Manager") and w.get("kCGWindowLayer",0)==0:
        b=w["kCGWindowBounds"]
        if b["Width"]>50 and (best is None or b["Width"]*b["Height"]>best[1]): best=(w["kCGWindowNumber"],b["Width"]*b["Height"])
if best: print(best[0])
PY
) || wid=""
if [ -z "$wid" ]; then
wid=$(swift - <<'SW'
import CoreGraphics
let l = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
var best: (Int, Double)?
for w in l where ["WindowsManagerApp", "Windows Manager"].contains(w["kCGWindowOwnerName"] as? String ?? "") && (w["kCGWindowLayer"] as? Int) == 0 {
  let b = w["kCGWindowBounds"] as? [String: Double] ?? [:]
  let a = (b["Width"] ?? 0) * (b["Height"] ?? 0)
  if a > 2500, best == nil || a > best!.1 { best = (w["kCGWindowNumber"] as? Int ?? 0, a) }
}
if let b = best { print(b.0) }
SW
)
fi
[ -n "$wid" ] || { echo "no WindowsManagerApp window for $name" >&2; exit 1; }
screencapture -l "$wid" -o "ux/shots/$name.png"
echo "ux/shots/$name.png"
