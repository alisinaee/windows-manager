# Research 04: Roadmap plan

## Question

In what order do we build Windows Manager, and how big is each step?

## Findings

- Space control on macOS 27 is unproven for this machine (03-risks R1-R3), so it is tested first.
- The MVP (capture + one-click restore) needs no private calls; Spaces come after.
- Reusable MIT building blocks exist (02-landscape).

## Decisions

```roadmap-plan
P P0 - | Research and plan
T P0.6 done 10 opus/medium | Landscape and risks notes (02, 03)
T P0.7 done 15 opus/medium | Roadmap plan and architecture map (04-plan, system.json)
P P1 todo | Spaces Lab (test tool on macOS 27)
T P1.1 todo 30 sonnet/medium | Swift package scaffold: WMCore library + spaceslab CLI, AX permission check
T P1.2 todo 40 sonnet/medium c:opus/8 | SkyLight read: Spaces per display in order, window to Space, full-screen owners
T P1.3 todo 40 sonnet/medium c:opus/8 | Bridged window move between Desktops with read-back check
T P1.4 todo 40 sonnet/medium | Full-screen tests: where a new Space goes, exit return, timing via AXFullScreen
T P1.5 todo 30 sonnet/medium | Desktop switch tests: synthetic Dock swipe and Ctrl+Arrow
T P1.6 todo 30 sonnet/medium | Add and remove Desktops through Mission Control accessibility
T P1.7 todo 20 sonnet/medium ! | Space order file test: backup, rewrite, Dock restart # you run it
T P1.8 todo 40 sonnet/medium | Virtual probes: app hide/unhide speed, corner parking, raw trackpad read
T P1.9 todo 10 opus/medium ! | Run every test on your Mac, write 05-lab-results and decisions # you run it
P P2 todo | MVP: capture and one-click restore
T P2.1 todo 40 sonnet/medium | Menu bar app scaffold (SwiftUI MenuBarExtra), build and run script
T P2.2 todo 60 sonnet/medium c:sonnet/10 | Accessibility bridge: windows, frames (size-pos-size), AXFullScreen, observers
T P2.3 todo 40 sonnet/medium | Display map: hardware UUIDs, relative frames, fallback when a monitor is missing
T P2.4 todo 30 sonnet/medium | Profile model and versioned JSON store
T P2.5 todo 60 sonnet/medium | Capture all windows, monitors, Desktops, full-screen Spaces and their order
T P2.6 todo 40 sonnet/medium c:sonnet/8 | Window matcher: bundle id, title, document, index
T P2.7 todo 40 sonnet/medium | App launcher: open closed apps, wait for windows, re-apply after settle
T P2.8 todo 80 opus/high c:opus/15 | Restore planner and engine: diff, steps, retries, progress
T P2.9 todo 50 sonnet/medium | Menu bar UI: profiles, Run, Capture, status
T P2.10 todo 20 haiku/low | Permission onboarding (Accessibility)
T P2.11 todo 30 haiku/low | Unit tests: model, matcher, planner
P P3 todo | Native Spaces engine
T P3.1 todo 50 sonnet/medium c:opus/10 | SkyLight bridge in the app: self-test and fallback flags
T P3.2 todo 50 sonnet/medium | Restore windows to saved Desktops, add missing Desktops
T P3.3 todo 80 opus/high c:opus/15 | Full-screen order rebuild from the first wrong slot
T P3.4 todo 60 sonnet/medium | Space guard: drift watch, Fix button, auto-fix, mru-spaces check
T P3.5 todo 40 sonnet/medium | Pin rules: app or window to Desktop on window creation
T P3.6 todo 40 sonnet/medium c:sonnet/8 | Apple binding backup and login repair
T P3.7 todo 40 sonnet/medium | Auto profile on monitor change, wake and unlock
P P4 todo | Layouts and zones
T P4.1 todo 50 sonnet/medium | Layout engine: grids, custom zones, split layouts
T P4.2 todo 80 sonnet/high | Layout editor: monitor mini map, drag apps into zones
T P4.3 todo 70 sonnet/high | Snap overlay: drag with a modifier key into zones
T P4.4 todo 25 haiku/low | Hotkeys for profiles and zones (KeyboardShortcuts)
P P5 todo | Virtual desktops
T P5.1 todo 50 sonnet/medium | Workspace model saved to disk, crash and lock recovery
T P5.2 todo 70 sonnet/high c:opus/12 | Hide and show engine: app hide plus corner parking
T P5.3 todo 40 sonnet/medium | Switching: hotkeys, follow Cmd+Tab and Dock clicks
T P5.4 todo 60 sonnet/high | Three-finger swipe from raw trackpad data
T P5.5 todo 40 sonnet/medium | Mixed mode: native full screen plus virtual workspaces
P P6 todo | Profiles plus
T P6.1 todo 80 sonnet/medium | Settings window: profile editor, window rules, monitor map
T P6.2 todo 60 sonnet/medium | Content restore: browser tabs, documents, VS Code folders
T P6.3 todo 40 sonnet/medium | wmctl CLI and URL scheme
T P6.4 todo 30 sonnet/medium | Shortcuts and Focus actions (App Intents)
T P6.5 todo 15 haiku/low | Import and export profiles
P P7 todo | Release
T P7.1 todo 5 haiku/low ! | Choose license (MIT suggested) and final app name # your choice
T P7.2 todo 30 sonnet/medium ! | Developer ID signing and notarization # needs your Apple developer account
T P7.3 todo 30 sonnet/medium | Sparkle updates and launch at login
T P7.4 todo 20 haiku/low | README, user guide, credits for MIT code
```

## Sources

- https://github.com/rxhanson/Rectangle
- https://github.com/nhnamp/dispace
- https://github.com/erango/monitor-glue
