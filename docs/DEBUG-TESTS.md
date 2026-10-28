# Debug mode and live challenge tests (spec, P6.68 to P6.74)

Design by Opus (J144). Workers: read this, build only your own files.

## Fixture profiles (one display, global points)
- **Challenge Work** (3 desktops): D1 TextEdit "A" 0,25,800x600 + Calculator top-right; D2 Notes 100,100,1000x700 + Finder ~/Documents 900,400,700x500; D3 Safari about:blank 0,25,1200x800 + TextEdit "B" 1250,25,600x500.
- **Home**: D1 Finder (~) left half + Notes right half; D2 Safari maximized (not fullscreen); Calculator on All Desktops; unlisted apps untouched.
- **Challenge Dup**: two TextEdit windows on D1, same title, different frames (matcher must not swap).

## Scenarios (scramble -> restore -> verify)
- S1 cold: fixture apps quit, 1 desktop. Expect launch + addDesktop.
- S2 wrong place: all apps open on D1, frames shifted +200 and 50% size, Safari on wrong desktop.
- S3 mixed: Notes minimized, TextEdit A fullscreen, Calculator hidden, Finder app running with no window.
- S4 extras: an extra TextEdit "C" not in the profile must stay untouched.
- S7 re-run: second restore is a no-op (0 moves, 0 launches).
(S5 unsaved doc, S6 Stage Manager: later.)

## Pass checks (poll up to 5 s after report done)
Each saved window has exactly one live match (CGWindowList + AX); on the target Space; position and size within 4 pt (or "clamped" note); AXMinimized false, fullscreen matches, not hidden; non-profile windows keep space and frame; no off-screen ghosts; every report step done or skipped with a reason.

## Debug panel
Bottom menubar button toggles Debug mode. Window: test list with a Run button each, one row per plan step (icon, kind, target, status pending/running/done/skipped/failed, timing), expandable saved/before/after, a per-desktop mini map refreshed ~250 ms (saved outlines, live boxes), Scramble / Restore / Verify / Copy result (JSON like lab-results). Writes a log file for outside review.
