# Research 02: Similar free GitHub projects

## Question

Which free projects already do parts of this app, what can we reuse (license), and what mistakes should we avoid?

## Findings

- No free project covers the full scope (profiles + monitors + Desktops + full-screen order + launch) (P0.2 search, 45 repos).
- Closest in scope: SpacePigeon (MIT, 92 stars, Hammerspoon + Swift helper, needs macOS 26.4+ for moves).
- Closest in concept: Dispace (no license, tested on 27.0.1): per display-setup Desktops and window frames; skips full-screen Spaces.
- Best monitor model: monitor-glue (MIT): monitor sets by hardware UUID, frames relative to monitor origin, restore on connect, wake, unlock, retry up to 3 min.
- Window matching: title first, then position or index (winlayout, monitor-glue). Two windows of one app is a known failure (SpacePigeon #11, #13).
- AX move tricks (Rectangle, MIT, 30k stars): size, position, size; turn AXEnhancedUserInterface off while moving; detect minimum size (>1 pt off); retry refused sizes after the move.
- Spaces, per job (P0.3): list and order = SLSCopyManagedDisplaySpaces; window Space = SLSCopySpacesForWindows; move = SLSBridgedMoveWindowsToManagedSpaceOperation run by SLSPerformAsynchronousBridgedWindowManagementOperation, then read back; switch = synthetic Dock swipe (InstantSpaces, InstantSpaceSwitcher, MIT) or Ctrl+Arrow; create or remove = Accessibility on Mission Control (Hammerspoon hs.spaces, MIT).
- On 27.0.1: yabai scripting addition and Hammerspoon moveWindowToSpace are reported broken; Dispace reports the bridged move working. Must be tested here.
- No project reorders native full-screen Spaces. yabai can only with SIP off.
- Do not parse com.apple.spaces for reading: a macOS 27 beta moved its keys (Apple forum 830748).
- Virtual workspaces (P0.4): app hide (FlashSpace) keeps Mission Control clean but hides all windows of an app; corner parking (AeroSpace, MIT) is per window but leaves a 1 px sliver.
- AeroSpace lost all assignments when a screen lock killed it on 26.3.1 (discussion 2007): persist assignments to disk.
- Gestures: OpenMultitouchSupport (MIT) reads raw touches but cannot stop the system swipe; iss (0BSD) uses a session event tap to drop the system swipe and post its own.
- Packages (MIT): KeyboardShortcuts, LaunchAtLogin-Modern, Sparkle 2, AXorcist (optional AX wrapper).
- GPL, learn only: FlashSpace, Loop, MacsyZones, OmniWM, alt-tab-macos. No license, learn only: Dispace.
- Complaints to avoid: apps stuck on the laptop after a monitor reconnects (FlashSpace #575); minimized windows coming back (FlashSpace #635); exact size not restored (HopTab #20, #21); sending Cmd+S to "save before quit" (SpacePigeon).

## Decisions

- Build our own Swift app; reuse MIT code with credit (Rectangle tricks, hs.spaces AX steps, InstantSpaces swipe, OpenMultitouchSupport, iss idea).
- Never copy GPL or unlicensed code; read only.
- Read Spaces through SLS calls, never by parsing com.apple.spaces; write that file only in binding repair, with backup.
- Every private call result is read back and verified; a failure flips that feature to its fallback.
- Use monitor-glue's monitor model and triggers; title-then-index window matching.
- Virtual mode: app hide by default, corner parking only for apps split across workspaces; assignments saved to disk.

## Sources

- https://github.com/louivers/spacepigeon
- https://github.com/nhnamp/dispace
- https://github.com/erango/monitor-glue
- https://github.com/rxhanson/Rectangle
- https://github.com/asmvik/yabai
- https://github.com/Hammerspoon/hammerspoon/issues/3903
- https://github.com/asmvik/yabai/issues/2844
- https://github.com/pavlohuk/InstantSpaces
- https://github.com/jurplel/InstantSpaceSwitcher
- https://github.com/nikitabobko/AeroSpace
- https://github.com/wojciech-kulik/FlashSpace
- https://github.com/joshuarli/iss
- https://github.com/Kyome22/OpenMultitouchSupport
- https://github.com/sindresorhus/KeyboardShortcuts
- https://github.com/sparkle-project/Sparkle
- https://developer.apple.com/forums/thread/830748
