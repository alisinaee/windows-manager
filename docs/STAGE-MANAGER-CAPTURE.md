# Stage Manager capture and restore design (P6.62)

Describes what the code does today (Sources/WMCore/System/StageManager.swift, Profiles/WorkspaceScanner.swift, Restore/RestorePlan.swift). Longer Studio context is in PLAN-profile-maps.md.

## Constraint
macOS has no public Stage Manager API. The engine never toggles Stage Manager and never asks the user to. It reads side effects at capture time and, at restore time, leaves windows it cannot reach alone.

## Reading the state
- On or off: `StageManagerProvider.live` reads `com.apple.WindowManager GloballyEnabled` (missing key = off). Stored as `Profile.stageManagerOn` (nil on old profiles or when unreadable). Tests inject `.fixed(...)`.
- Per window, `StageManager.classify` gives `active`, `strip` or `unknown`, with an `isHeuristic` flag:
  1. Strip thumbnail (certain): the strip draws a small copy of the real window with the same window id. `WorkspaceScanner.isStripThumbnail` calls it a thumbnail when Stage Manager is on, the window is on screen, has an AX frame, and the window-server bounds cover under 25% of that frame. The thumbnail keeps the real AX frame and the server bounds (`serverBounds`).
  2. Minimized, full-screen or hidden-app windows: unknown, never marked.
  3. On screen: active (group 0), on any Space.
  4. Not on screen but on the current Space: strip or another stage, a guess.
  5. Frame almost entirely off every monitor (under 10% visible): strip, a guess (older macOS parks windows there).
  6. Anything else: unknown.
- Grouping into stages (`StageManager.annotate`): thumbnails are clustered per display by vertical gap under 10 pt along the strip (`clusterThumbnails`), numbered 1... top to bottom; these groups are certain. Other strip windows are grouped by app (bundle id, else name) as a guess, numbered after the thumbnail stages. Hand-built stages that mix apps cannot be told apart from the default one-stage-per-app layout when no thumbnail is visible.

## What is saved
`WindowSnapshot.stage: SavedStage?` = `{group, isActive, isHeuristic}`, absent when Stage Manager was off or unknown, plus `Profile.stageManagerOn`. `LiveWindow.isInStageStrip` is transient and not saved. The saved frame of a strip window is its old position, kept only as information.

## Restore rules (RestorePlan)
- Stage Manager on now: live windows that are in the strip are removed from the plan with a warning ("N windows in the strip or another stage ... left alone"). They are not moved, and their app is not raised, because moving one would only pull it into the active stage.
- A saved window with `stage.isActive == false` is likewise left alone with a warning, even if it is reachable now.
- A saved window not found while its app has strip windows is not reported as lost: `absorbStageManagerUnmatched` lists it as possibly in the strip (shown as "may be in a stage" in the status overlay).
- Saved and current Stage Manager state differ: one warning ("was on/off when captured and is on/off now"); the restore still runs.
- Stage Manager is not a restore option; Options shows the saved state as text only.

## Limits
- Heuristic groups may be wrong; they carry `isHeuristic` so the UI can say so.
- With Stage Manager on, windows of other stages are invisible to the capture unless their thumbnails are on screen; they are then captured at their real frame with a stage group.
- Recreating a stage (which windows share the active stage) is not done: no API, and synthetic strip clicks are fragile. Out of scope until Apple exposes it.
- Verify live behaviour with `wm debug run` (only when asked; it moves real windows) and `wm doctor` (reports the Stage Manager setting).
