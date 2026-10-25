# Research 01: Project brief

## Question

What is Windows Manager, who is it for, and what must the first version do?

## Findings

- Goal: profiles (Home, Work, ...) that save every app's window: monitor, position, size, full screen, Desktop (Space). One click restores the profile.
- Restore rules: closed apps are opened, open apps are only moved, full screen and Desktop are put back.
- Must capture the whole workspace (all monitors, all Desktops, full-screen apps) in one step.
- Must support split layouts and custom zones on one screen.
- Must stop macOS from reordering Desktops and full-screen Spaces (user pain: A, Desktop, B, C, D becomes B, C, Desktop, A, D).
- User machine (2026-10-25): macOS 27.0.1 (26A434), Apple M5 Pro, MacBook screen 3024x1964 + Samsung U32R59x.
- Current layout, Samsung (main display): [Chrome FS] [Telegram FS] [Desktop 1] [Arc FS] [Claude FS]; MacBook: [VS Code FS] [VS Code FS] [Desktop] (spaceslab spaces, P1.2).
- Stage Manager is ON (com.apple.WindowManager GloballyEnabled = 1).
- "Automatically rearrange Spaces based on most recent use" is ON (com.apple.dock mru-spaces = 1): the direct cause of the reordering.
- "Displays have separate Spaces" is ON (com.apple.spaces spans-displays = 0).
- com.apple.spaces keeps per-display Space order (SpaceAssignments > ManagedSpaceOrdering) and, per full-screen Space, the owner pid and window id (fs_wid).
- Moving windows between Spaces works with SIP on from macOS 26.4 via SLSBridgedMoveWindowsToManagedSpaceOperation (yabai 7.1.25; Dispace tested on 27.0.1).
- Apple app-to-Desktop bindings lose entries after a cold boot on macOS 27.0/27.0.1 (open Apple bug).
- One test on macOS 26 found new full-screen Spaces are appended at the end of the list.

## Decisions

- Native Swift + SwiftUI menu bar app, macOS 26+, Developer ID + notarization (no App Store: private SkyLight calls).
- Permissions: Accessibility (required); Screen Recording only for optional thumbnails.
- Three Space modes: Native (default), Virtual (own workspaces), Mixed.
- Native mode: own window-move engine + full-screen order rebuild + drift guard + login-time binding repair + own pin rules.
- All private calls live in one module with a launch self-test and automatic fallback to Virtual mode.
- Phase order: Spaces test tool first (verify on macOS 27), then MVP (capture + one-click restore), then the rest.
- Code stays in local git (no remote for now).

## Sources

- https://github.com/asmvik/yabai/blob/master/CHANGELOG.md
- https://github.com/nhnamp/dispace
- https://communities.apple.com/de/thread/256361881
- https://github.com/lucaspinheirogit/macos-spaces-auto-layout/issues/41
