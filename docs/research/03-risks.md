# Research 03: Risks and mitigations

## Question

What can break this app, and what does each risk turn into in the plan?

## Findings

- R1 Private SkyLight calls change with macOS point releases (yabai ships fixes per release; Hammerspoon move broken on 27.0.1).
- R2 Full-screen Space placement is unconfirmed on 27 (one test on 26: appended at the end).
- R3 Synthetic mouse events are ignored by Mission Control on 27.0 (PaperWM.spoon #173): drag tricks are dead.
- R4 Apple app-bindings are lost after a cold boot on 27.0.x (Apple Community thread).
- R5 Accessibility-only: sandboxed builds cannot control other apps, so no Mac App Store.
- R6 Apps that fight moves: minimum sizes, Electron apps resizing after launch, windows without AX.
- R7 Many windows per app (Chrome, Terminal): wrong match puts a window in the wrong place.
- R8 Monitor changes: missing monitor, different resolution, monitor appears at the lock screen.
- R9 Virtual mode: a crash or screen lock can leave windows hidden or parked.
- R10 Gestures: the system three-finger swipe fights ours.
- R11 License: copying GPL code would force GPL on the app.
- R12 Writing com.apple.spaces can corrupt the user's Spaces.
- R13 Stage Manager (ON here) groups and moves windows itself and adds overlay windows; restores and hiding may fight it.

## Decisions

- R1: all private calls in one SkyLight bridge; runtime symbol lookup; launch self-test with read-back; fallback to Virtual mode with a clear message (P3.1).
- R2, R3: Spaces Lab measures placement, exit behavior and switching on the user's Mac before the engine is built (P1).
- R4: own pin rules plus login-time binding repair with backup (P3.5, P3.6).
- R5: ship outside the App Store, Developer ID + notarization (P7.2, needs the user's Apple account).
- R6: Rectangle's size-position-size and AXEnhancedUserInterface handling, settle-and-reapply after launch, minimum-size warning (P2.2, P2.7).
- R7: matcher by bundle id, title pattern, document and index, with per-window rules in the editor (P2.6).
- R8: monitor-glue model, retries after unlock, proportional fallback to the remaining screen (P2.3, P3.7).
- R9: assignments saved to disk; on quit, crash or relaunch all windows are shown again (P5.1).
- R10: offer four fingers for macOS, or an event-tap mode that takes the swipe (P5.4).
- R11: credits file for MIT code; GPL and unlicensed code read only (P7.4).
- R13: Spaces Lab records Stage Manager state in every test; the app detects it, ignores its overlay windows and offers to turn it off per profile.
- R12: timestamped backup before every write, one-click restore, experiments run by the user (P1.7, P3.6).

## Sources

- https://github.com/asmvik/yabai/blob/master/CHANGELOG.md
- https://github.com/Hammerspoon/hammerspoon/issues/3903
- https://github.com/mogenson/PaperWM.spoon/issues/173
- https://communities.apple.com/de/thread/256361881
- https://github.com/lucaspinheirogit/macos-spaces-auto-layout/issues/41
- https://github.com/rxhanson/Rectangle
- https://github.com/erango/monitor-glue
