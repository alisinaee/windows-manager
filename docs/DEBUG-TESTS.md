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

# Power-user challenge suite (P6.116, Opus plan)
Real bug from the user's log: V2BOX (fixed 385x616) and System Settings (fixed width 740) accept the position but refuse the size; the step was marked failed. Rule: position within 4pt + step "done (size limited)" + limit learned + second run plans 0 steps.
Always INCONCLUSIVE when: Stage Manager on (desktop checks), fewer desktops than needed, single display for 2-monitor scenarios, missing permission.
Scenarios (ids for `wm debug run --scenario`): 1 deep-work (TextEdit/Terminal/Safari in thirds D1, Preview bottom half D2; scramble stacked at half size) | 2 meetings (FaceTime right third + Notes left two thirds on D2, Reminders D1; Notes minimized) | 3 vpn-tools (Calculator fixed, System Settings fixed width, About This Mac panel, V2BOX if installed; impossible saved sizes like 960x1015; 2nd run 0 steps) | 4 design-2mon (huge Preview 1800x1100, windows off-screen at negative coords; on 1 display must be pulled on screen) | 5 home-work (apply Work while Home windows open; Home-only windows untouched; All Desktops Calculator stays) | 6 partial (D2 only / display 2 only; the rest byte-identical; needs RestoreScope P6.117+) | 7 mixed-states (minimized, hidden, closed cold launch, full screen, Finder no window) | 8 dupes (3 TextEdit Untitled, 2 Finder same folder; no swaps) | 9 slow-front (cold Music/Activity Monitor while Terminal frontmost; wait up to 15s; focus ends per profile) | 10 twice-minsize (saved 120x80 below min; learn min; run 2 = 0 steps).
Panel: row per scenario with PASS/FAIL/INCONCLUSIVE/SKIPPED (missing app); size-limited steps amber; learned limits hatched on the mini map. CLI: `--list`, `--json`, exit 0 pass 1 fail 2 inconclusive.
Tasks: fixtures DebugFixtures.swift (haiku) | scramble additions DebugScramble.swift (haiku) | verify rules DebugVerify.swift + DebugRunReport.swift (sonnet: size-limited pass, idempotence, inconclusive, dup ids) | runner registry + CLI (sonnet) | panel (haiku) | docs (haiku). Order: fixtures, scramble, docs parallel; then verify; then runner+panel.
