# Plan: Profile Map viewer and visual Profile Builder

Status: design approved by the design lead, not started. Scope: two features asked for by the owner.

1. **Profile Map**: a browsable picture of a saved profile (monitors, Spaces per monitor in Mission Control
   order, full-screen and Split View Spaces, windows at their real positions, Stage Manager state), with a
   "compare with now" overlay and Restore from the map.
2. **Profile Builder**: make or edit a profile on the same map: pick apps, place them on monitors, Desktops
   and positions (snap to Layout zones), set restore options, order the launch of closed apps with waits,
   preview the restore (dry run) and save.

Constraints that shape everything below: SwiftPM + Command Line Tools, so **no `@State`, no `#Preview`, no
other macros** in the app target (state lives in `ObservableObject` models, `@StateObject`/`@ObservedObject`/
`@Published`, `@FocusState` and `@Environment` are fine). Tests exist only for `WMCore`, so every rule that can
be pure lives in `WMCore` and is unit tested; SwiftUI files stay thin.

---

## Three key decisions

1. **One window, two modes.** A new resizable window, **Profile Studio**, holds a profile list on the left
   and one map canvas. Viewing a profile is the Map; pressing **Edit** turns the same canvas into the Builder
   (same geometry code, same drawing). A new profile is just the Builder on an empty draft. No new Settings
   tab (Settings is fixed at 680x480, too small for a map).
2. **The overlay and the preview come from the real planner.** "What is missing now" and "Preview restore"
   both come from one `RestorePlan` made by the existing `RestorePlanner` (new public
   `RestoreEngine.preview(_:)`), projected onto the map by a pure `ProfileLiveStatus`. No second diff engine
   that could disagree with what Run does.
3. **Additive, optional data model; schemaVersion stays 1.** Built windows are ordinary `WindowSnapshot`s
   marked `origin = .planned`; launch order lives in a new optional `Profile.launchPlan`. Old files decode
   unchanged and re-encode byte-identical; old builds ignore the new keys.

---

## A. Information architecture

| Item | Decision |
| --- | --- |
| Window | `Profile Studio` (NSWindow via `ProfileStudioWindowController`, like `LayoutEditorWindowController`). Min 960x600, remembers frame (`setFrameAutosaveName("ProfileStudio")`). Title: `Profiles - <name>`; `Profiles - New profile` while building. |
| Layout | Sidebar (profile list, 220 pt) / Canvas (flexible) / Inspector (280 pt, collapsible with the toolbar button or Cmd+Opt+I). |
| Modes | `View` (read only, Restore available) and `Edit` (Builder). Toolbar shows `Edit` in View; `Cancel` + `Save` in Edit. |
| Menu bar | New row `Profiles…` under `Layouts…` opens the Studio on the last selected profile. The status line after a capture gets a trailing `Show map` button (opens the new profile). |
| Profiles tab (Settings) | Detail form gains `Open Map…` and `Edit in Studio…`; list footer gains `New Profile…` (opens Builder). Rename/Duplicate/Export/Delete stay where they are. |
| URL | `windowsmanager://show?profile=Work` opens the Studio on that profile (later, optional, task U8). |
| Naming | Feature names in UI: "Map", "Edit", "Launch order", "Preview restore", "Compare with now". Planned windows are called "planned windows" in UI text and docs; captured ones need no label. |

Navigation: selecting another profile in the sidebar while Edit has unsaved changes asks **Save / Don't Save /
Cancel** (same sheet as closing the window). Esc in Edit = Cancel (with the same prompt when dirty).

---

## B. Screens

### B1. Map viewer (View mode)

```
+--------------------------------------------------------------------------------------------------+
| [sidebar]  | Work            Captured 12 Oct 14:03 · 3 monitors · 9 Spaces · 14 windows   [Edit]  |
|  Home      | Stage Manager: off at capture   [Compare with now ◻] [Zoom - ▮ +] [Preview…] [Run]   |
| >Work  14  |----------------------------------------------------------------------------------|
|  Gaming 3  |        +---------------------------+  +------------------------------+          |
|            |        | Studio Display  (main ★)  |  | DELL U2723                   |          |
|            |        | +-------+  +-------------+|  | +--------------------------+ |          |
|            |        | |Safari |  | Xcode       ||  | | Slack                    | |          |
|            |        | |"Inbox"|  |             ||  | |                          | |          |
|            |        | +-------+  +-------------+|  | +--------------------------+ |          |
|            |        +---------------------------+  +------------------------------+          |
|            |        [D1][D2*][⛶ Music][D3]  +       [D1*][D2]                                 |
|            |                                                                                  |
|            |        Minimized: Notes "Todo"   ·   On all Desktops: 1Password mini              |
|            |----------------------------------------------------------------------------------|
|            | Legend: ✓ in place  ↔ will move  ↑ will launch  ⚠ not found  ◌ Desktop missing  |
| [+ New] [⌄]|                                                                                  |
+--------------------------------------------------------------------------------------------------+
```

- **Monitors** are drawn in their saved physical arrangement (same math as `MonitorsSettingsTab`, moved to
  `ProfileMapLayout`). Each monitor tile shows **one Space at a time**: the selected one (default: Desktop 1,
  or the Space that has the most windows when Desktop 1 is empty).
- **Space strip** under each monitor, Mission Control order: `D1 D2 [⛶ Music] D3`. Desktops show a mini
  thumbnail; a full-screen Space shows the app icon filling the thumbnail; Split View shows two icons side by
  side. Selected thumbnail has an accent border plus a bold label (not color only). Click selects it on that
  monitor; Cmd+[ / Cmd+] steps through the focused monitor's Spaces; Tab moves focus between monitors.
- **Full-screen Space on the canvas**: selecting it fills the monitor tile with that window (two halves for
  Split View) and a `Full screen` badge.
- **Windows**: rounded rectangles at `relativeFrame` of the monitor's visible area, back to front by
  `zIndex`. Fill = per-app tint (stable hash into an 8-color palette with light and dark variants) at 22%,
  1 pt stroke, app icon (16 pt, `NSWorkspace.icon(forFile:)` from bundle id, generic icon fallback), app name,
  title on a second line when it fits. Windows with `restore == false` are drawn hatched at 40% with
  "Not restored". "On all Desktops" windows are drawn dashed on every Desktop and listed in the tray.
  Minimized and unknown-placement windows go to the **tray row** below the strips (they have no place).
- **Hover** (pointer only, never required): a tooltip-sized card with app, title, Desktop, frame in points.
  **Selection** (click or keyboard) shows the same card in the Inspector, plus document path, match rule
  (title match), z order and, when Compare is on, the planned steps for that window in plain words
  ("Move to Desktop 2 on DELL, then resize to 1200x800").
- **Disconnected monitor**: tile drawn with diagonal hatching and `Not connected - windows go to <mapped
  monitor>` using `DisplayMap.match`, or `- windows stay where they are` when nothing maps.
- **Zoom**: Fit (default, Cmd+0), 50-200% via Cmd+= / Cmd+- and the toolbar slider; the canvas scrolls when
  zoomed. Pinch on the trackpad maps to the same zoom value. No zoom animation under Reduce Motion.
- **Compare with now** (Cmd+L toggle, off by default because it scans): runs `RestoreEngine.preview` off the
  main thread; while running the toolbar shows a small spinner and "Comparing with your Mac…"; the map keeps
  working. Results draw a corner badge on every window and Space using `WindowLiveStatus`:
  `✓ in place`, `↔ will move/resize/change Desktop`, `↑ app will launch`, `⚠ not found` (reason in the
  card), `– not restored`; Spaces: `◌ Desktop missing` (dashed thumbnail, "will be added" when the profile
  allows it). A one-line summary sits above the canvas: "8 in place, 4 will move, 2 apps will launch, 1 not
  found". Refreshes when the window becomes key again, and with Cmd+R. Never polls.
- **Preview…** opens the **Restore preview sheet** (B3). **Run** runs the profile through `AppState.run`
  (same busy and Accessibility rules; disabled with a reason in the help tag when not allowed).
- **Stage Manager**: header text "Stage Manager: on at capture" / "off at capture" / hidden when unknown
  (nil, old profiles). When Compare is on and the live state differs, the planner's warning is shown here.

States: no profiles (sidebar empty) -> centered empty state with two buttons `Capture current workspace` and
`Build a profile`; profile with no windows -> map draws monitors and Spaces plus "No windows. Press Edit to
add apps."; profile file unreadable -> error panel with the `ProfileStoreError` text and `Show in Finder`;
no displays at all (headless) -> "No displays found" and the map still lists Spaces as text.

### B2. Builder (Edit mode, same canvas)

One canvas, not a wizard: people jump between placing and ordering. A **step bar** in the toolbar shows
progress and doubles as navigation: `1 Monitors · 2 Apps · 3 Place · 4 Options · 5 Launch order · 6 Preview
· 7 Save`; each step gets a check mark when its validation passes; clicking a step focuses the matching
panel.

```
+--------------------------------------------------------------------------------------------------+
| Name [Work________] Icon [▾]   1 Monitors ✓ · 2 Apps ✓ · 3 Place · 4 Options · 5 Order · 6 Preview |
|                                                     [Undo][Redo]   [Cancel]  [Preview…]  [Save] |
|---------------+-----------------------------------------------------------+-------------------|
| App library   |  +----------------------+  +----------------------+       | Inspector         |
| [Search____]  |  | Studio Display       |  | DELL U2723           |       | [Window|Options|  |
| (Running)     |  |  ┌zone┐┌──zone──┐    |  |                      |       |  Launch order]    |
|  Safari     ● |  |  │    ││ Xcode  │    |  |   drop apps here     |       | Safari "planned"  |
|  Xcode      ● |  |  └────┘└────────┘    |  |                      |       | Monitor [Studio▾] |
| (Installed)   |  +----------------------+  +----------------------+       | Space   [D2 ▾]    |
|  Music        |  [D1][D2*][⛶ +] [+ Desktop]   [D1*] [+ Desktop]           | Zone    [Left ▾]  |
|  Notes        |                                                           | x 0% y 0% w 50%.. |
| (From capture)|  Layout zones: [Halves ▾] [Snap ✓]                        | ◻ Full screen     |
|  Slack        |                                                           | ◻ Minimized       |
| [+ Add app…]  |                                                           | ✓ Restore window  |
+---------------+-----------------------------------------------------------+-------------------+
```

**Step 1, Monitors / source.** Starting points, shown as a sheet when the Builder opens on a new profile:
`Blank on these monitors` (current `DisplayMap.current()`, default), `Start from current workspace` (runs a
capture into the draft, not saved), `Start from a copy of <profile>`, `Start from a Layout` (pre-creates one
empty Desktop per monitor with that Layout's zones shown). Editing an existing profile skips the sheet and
keeps its saved monitors; saved monitors that are not connected are drawn hatched and stay editable.
`Use current monitors instead…` remaps all windows with `DisplayMap.mapFrame` (undoable).

**Step 2, Apps.** Library sections: `Running` (regular apps, live dot), `Installed` (scan of /Applications,
/System/Applications, ~/Applications, one level deep, cached per Studio session), `In this profile`. Search
filters all three. `Add app…` opens an NSOpenPanel on .app bundles. An app can be added without placing it
(context menu `Launch only, no window`), which creates a launch-order entry with no window.

**Step 3, Place.** Drag an app from the library onto a monitor tile: creates a planned window on the selected
Space of that monitor. With Snap on and a Layout chosen for that monitor (picker lists `LayoutStore` layouts
that `matches(display:)`), the zone under the pointer highlights and the window takes the zone rect; Option
while dropping/dragging disables snapping; without zones the window gets 50% x 70% centered at the drop
point, clamped inside. Dropping on a Space thumbnail places it on that Space at the default rect. Existing
windows (captured or planned) can be dragged (move) and resized by edge handles (reuse `EdgeHandle` /
`CursorHold`), snapping to zones, to monitor edges and to other windows' edges within 8 pt (screen) when Snap
is on. Dragging a window onto another monitor tile or a Space thumbnail moves it there.
Spaces: `+ Desktop` appends a Desktop (max 16 per monitor), `⛶ +` makes the selected window full screen in a
new full-screen Space after the selected Space; context menu on a thumbnail: `Move left/right`, `Delete`.
Deleting a Desktop that has windows asks: `Move 3 windows to Desktop 1` (default) / `Delete windows` /
`Cancel`. Full-screen Spaces can be reordered; Desktops keep their numbers (they are renumbered from order).

**Pointer-free alternatives (required, WCAG 2.5.7).** Every drag has an equivalent: Inspector pickers
(Monitor, Space, Zone) and x/y/w/h percentage fields; library context menu `Add to <monitor> > <Space>`;
`Return` on a focused library app places it on the focused Space; arrows nudge the selected window 1% (Shift
10%), Option+arrows resize; Cmd+1…9 snap to zone N of the current Layout; Delete removes the window (planned)
or unticks Restore (captured windows are never deleted silently: `Delete` on a captured window asks once).

**Step 4, Options** (Inspector tab `Options`): grouped Form, every row with a one-line explanation.

| Control | Field | Default for new profiles |
| --- | --- | --- |
| Launch closed apps | `options.launchMissingApps` | on |
| Add missing Desktops (up to 8 per run) | `options.addMissingDesktops` (new) | on for built profiles, off for captured |
| Move windows to their Desktops | `options.restoreSpaces` | on |
| Restore full-screen apps | `options.restoreFullScreen` | on |
| Restore full-screen order | `options.restoreSpaceOrder` | on |
| Other apps: Leave / Hide / Quit (asks first) | `options.otherApps` | Leave |
| Hotkey | link "Set in Hotkeys tab" | - |

Stage Manager is not an option (the engine never toggles it); the Options tab shows the saved state as text.

**Step 5, Launch order** (Inspector tab `Launch order`, also openable as a wide sheet for long lists):

```
 Mode: (•) One after another   ( ) All at once (faster)          Est. worst case: 46 s
 ┌──┬────┬──────────────┬──────────────────┬───────────┬──────────┬────────┐
 │≡ │ 1  │ ● Xcode      │ Wait for windows │ then 2.0 s│ max 30 s │ ◻ front│  [↑][↓]
 │≡ │ 2  │ ○ Slack      │ Wait for app     │ then 0 s  │ max 20 s │ ◻ front│
 │≡ │ 3  │ ○ Music      │ Wait for app     │ then 0 s  │ launch only (no windows)   │
 │  │ –  │ Safari (running now: skipped at run)                                     │
 └──┴────┴──────────────┴──────────────────┴───────────┴──────────┴────────┘
 [ timeline: ███Xcode███▒2s▒██Slack██░Music░ ]   Apps not in the list launch last, in profile order.
```

Rows: drag handle, Move up/down buttons (and Cmd+Option+Up/Down), enabled checkbox (unticked = never launch,
windows are still placed if the app is running), wait mode (`Wait for windows` = minWindows from the number of
restorable windows, `Wait for app ready` = minWindows 0), `then wait` 0-60 s stepper (0.5 s steps), timeout
5-120 s, `Bring to front`. A status dot shows running now (●) / not running (○) / not installed (⚠, from the
library scan). The timeline is a simple proportional bar of worst-case time (timeout + delay per app),
recalculated as you edit; no animation under Reduce Motion. In `All at once` mode the per-row delay is
disabled with the help text "Delays apply only when apps launch one after another".

**Step 6, Preview** opens B3 for the in-memory draft (no save needed).

**Step 7, Save**: `Save` (Cmd+S) validates (`Profile.validate()` + `ProfileDraftCheck`); blocking problems
are shown inline next to the field or on the window/Space they concern, plus a count in the step bar; on
success the Studio returns to View mode on the saved profile. Duplicate names get the existing
`ProfileTransfer.uniqueName` rule. Warnings (for example "Safari is planned with 3 windows; an app usually
opens 1 window when launched, the other 2 are placed only if they already exist") never block saving.

**Undo**: model-level history of whole `Profile` drafts (value type; cap 200 entries; one entry per drag end,
not per drag tick). Cmd+Z / Shift+Cmd+Z, toolbar buttons. Cancel discards the draft (prompt when dirty).

### B3. Restore preview sheet (used by View and Edit)

```
 Preview restore of "Work"                                   [Refresh]  [Close]  [Run now]
 ⚠ 2 warnings     DELL U2723 is not connected: its windows go to Studio Display.  …
 ① Launch (one after another): Xcode → wait for windows, 2 s → Slack → Music          ~ up to 46 s
 ② Add Desktops: 1 to Studio Display
 ③ Move to Desktop: Safari "Inbox" → Desktop 2  ·  …
 ④ Place windows: 6     ⑤ Full screen: Music     ⑥ Other apps: hide 3 (Mail, …)
 Not found (1): Notes "Todo" - the app could not be found on this Mac
```

Phases come from `RestorePlan.phases` with `RestorePhase.title`, each group collapsible (collapsed when > 6
steps). `Run now` is disabled while Accessibility is not allowed or another run is busy, with the reason as
text. Quit steps are listed as "asks before quitting".

### B4. Visual system, accessibility, motion

- Native look only: system fonts (`.body`, `.callout`, `.caption` minimum 11 pt on the canvas), semantic
  colors (`windowBackgroundColor`, `controlBackgroundColor`, `separatorColor`, accent), SF Symbols, no
  custom chrome. Light and dark both checked; app tints come from a palette with separate light/dark values
  that keep 4.5:1 for label text on the tinted fill (labels use `.primary`, never white-on-tint).
- Status never by color alone: every status has a symbol and text (`checkmark.circle`, `arrow.left.arrow.right`,
  `arrow.up.forward.app`, `exclamationmark.triangle`, `circle.dashed`).
- VoiceOver: canvas is `.accessibilityElement(children: .contain)` labelled "Map of <profile>"; each monitor a
  container ("Studio Display, main, showing Desktop 2 of 4"); each window an element: label "Safari, Inbox",
  value "Desktop 2, left half, will move", custom actions `Move to Desktop…`, `Make full screen`, `Remove`,
  `Snap to zone…`; Space thumbnails are buttons "Desktop 2, 3 windows, selected". Launch-order rows expose
  `Move up` / `Move down` actions. Icon-only toolbar buttons get labels and help tags.
- Keyboard: full tab order Sidebar -> toolbar -> canvas (monitors, then windows in z order) -> Inspector;
  visible focus rings kept. Shortcuts: Cmd+E Edit, Cmd+S Save, Esc Cancel, Cmd+L Compare, Cmd+R refresh,
  Cmd+Shift+P Preview, Cmd+0/=/- zoom, Cmd+[ / ] Space, arrows/Option+arrows nudge/resize, Cmd+1-9 zone,
  Delete remove, Cmd+Z/Shift+Cmd+Z.
- Reduce Motion (`@Environment(\.accessibilityReduceMotion)`): no animated zoom, Space switch or drag
  springs; otherwise 0.15-0.2 s ease-out only.
- RTL: chrome uses leading/trailing and mirrors normally; the canvas is physical geometry, so it is wrapped in
  `.environment(\.layoutDirection, .leftToRight)` and never mirrored.

---

## C. Data model and engine changes

All new fields are optional or have defaults through `decodeIfPresent`; `Profile.currentSchemaVersion`
stays **1**. Rationale: bumping to 2 makes older builds refuse the files (`unsupportedSchema`); additive keys
are ignored by older decoders. Known cost: an older build that re-saves (rename) a new profile drops the new
keys; acceptable (single user, app auto-updates via Sparkle). Optional values are encoded only when non-nil
(custom `encode(to:)` with `encodeIfPresent`) so old profiles re-encode byte-identical (test asserts it).

New file `Sources/WMCore/Profiles/LaunchPlan.swift`:

```swift
public struct LaunchPlan: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable { case sequential, parallel }
    public var mode: Mode                   // default .sequential
    public var items: [LaunchItem]          // explicit order; apps not listed launch after, in profile order
}
public enum LaunchWait: String, Codable, Sendable { case windows, appReady }
public struct LaunchItem: Codable, Hashable, Sendable, Identifiable {
    public var app: AppRef
    public var enabled: Bool                // default true; false = never launch (still placed if running)
    public var wait: LaunchWait             // default .windows
    public var delayAfter: TimeInterval     // default 0, clamped 0...60, sequential mode only
    public var timeout: TimeInterval?       // nil = LaunchOptions.defaultTimeout, clamped 5...120
    public var activates: Bool              // default false
    public var withoutWindows: Bool         // default false; true = "launch only", no window expected
    public var id: String                   // identity key: lower-cased bundle id, else "name:<lower name>"
}
```

Changes to existing types (`Profile.swift`):

| Type | New field | Default when missing | Used by |
| --- | --- | --- | --- |
| `Profile` | `launchPlan: LaunchPlan?` | nil = today's behavior (parallel, 4 at a time) | planner, engine, Builder |
| `ProfileOptions` | `addMissingDesktops: Bool` | false | engine (`config.addMissingDesktops OR this`) |
| `WindowSnapshot` | `origin: WindowOrigin?` (`.captured`, `.planned`) | nil = captured | map drawing, Builder delete rules, warnings |
| `WindowSnapshot` | `zoneName: String?` | nil | Inspector label only ("Left half") |
| `Profile` | `apps` | unchanged, plus new `launchApps` = `apps` ∪ launch-only items | otherApps, library |

Planned windows: `title` nil, `titleMatch .any`, `documentPath` nil, `indexInApp` = order among that app's
windows, `relativeFrame` from the canvas, `frame` = relativeFrame on the display's `visibleFrame` (same
convention as capture; Layout zones are applied on the visible frame like `SnapController`, so a zone rect is
the relative frame). The matcher already matches by app + position when there is no title, so no matcher
change. A full-screen planned window gets `isFullScreen = true`, `relativeFrame 0,0,1,1`, its own
`SpaceSnapshot(kind: .fullScreen, fullScreenWindowIDs: [id])`.

Planner (`RestorePlan.swift`):
1. `planLaunch` orders `.launch` steps by `LaunchSequence.order(profile)`: enabled `launchPlan.items` first,
   then remaining apps in `profile.apps` order; disabled items get no step and their unmatched reason becomes
   "launching this app is switched off in Launch order".
2. Launch-only items (`withoutWindows`) whose app has no live window get `.launch(app:, windowCount: 0)` (the
   launcher returns `.alreadyRunning` quickly when it is running in the background).
3. `planOtherApps` uses `profile.launchApps`, so a launch-only app is never hidden or quit by the same restore.
4. `RestoreStep.launch` keeps its shape (tests compare steps); per-app options travel separately (below).

Engine (`RestoreEngine.swift`):
1. `LaunchRequest` gains `options: LaunchOptions?` and `delayAfter: TimeInterval` (defaults nil / 0, so fake
   environments compile unchanged). The live environment uses `request.options ?? LaunchOptions(minWindows:)`.
2. `runLaunch`: build requests from `LaunchSequence.requests(profile:steps:)`. Sequential mode: one
   `environment.launchAll([request])` at a time, emit `stepStarted/stepFinished` per app, then
   `environment.sleep(delayAfter)` unless the result is `.alreadyRunning`; check `Task.isCancelled` before each
   app (remaining apps reported skipped "cancelled"). Parallel mode or `launchPlan == nil`: today's code path.
3. `addMissingDesktops` = `configuration.addMissingDesktops || profile.options.addMissingDesktops`.
4. New `public func preview(_ profile: Profile) async -> (plan: RestorePlan, scan: WorkspaceScan)`: scan (off
   main, existing environment), `evaluate`, no side effects. The Map and the preview sheet use only this.

Risks: sequential launch is slower (worst case = sum of timeouts; mitigated by the estimate in the UI and
cancel); `windowCount: 0` launch steps must not count as "unmatched"; an app that only opens one window on
launch cannot satisfy several planned windows (warned in Builder, not fixed in this plan).

---

## D. Components

Pure, unit-tested (`Sources/WMCore/ProfileMap/` unless noted):

| File | Responsibility |
| --- | --- |
| `Profiles/LaunchPlan.swift` | types above, Codable defaults, clamping |
| `ProfileMap/LaunchSequence.swift` | effective order, `requests(profile:steps:)` -> `[LaunchRequest]` with `LaunchOptions`, `validate(_:profile:installed:) -> [DraftIssue]`, `worstCaseDuration` |
| `ProfileMap/ProfileSpaceIndex.swift` | windows per Space (desktop number, full-screen owners, all-Desktops, tray for minimized/unknown), default selected Space per monitor |
| `ProfileMap/ProfileMapLayout.swift` | canvas geometry: monitor rects from saved arrangement (fit, zoom, min tile 120 pt, 24 pt gaps when monitors touch), content rect per monitor (visible frame part), Space strip thumbnail rects, window rects from `relativeFrame` (clamped for drawing), `hitTest(point) -> MapHit` |
| `ProfileMap/MapSnapping.swift` | snap a dragged rect: Layout zones (via `Layout.zone(atX:y:)`), monitor edges, sibling edges, threshold in canvas points converted to relative units; `placeDefault(at:)` |
| `ProfileMap/ProfileDraftEditor.swift` | mutations on a `Profile` draft: add/remove/move Desktop, add/remove/reorder full-screen Space, place/move/resize/remove window, set full screen/minimized, renumber positions and `desktopNumber`, keep `placement` in sync, remap to other monitors |
| `ProfileMap/EditHistory.swift` | generic undo/redo stack with cap and coalescing key |
| `ProfileMap/ProfileDraftCheck.swift` | builder validation (Desktop count <= 16, planned windows per app vs launch behaviour, windows on missing Spaces, full-screen Space without owner) + `Profile.validate()` |
| `ProfileMap/ProfileLiveStatus.swift` | `RestorePlan` + profile -> `[UUID: WindowLiveStatus]`, `[SpaceKey: SpaceLiveStatus]`, summary counts |
| `ProfileMap/ProfileMapText.swift` | ASCII rendering of a `ProfileMapLayout` for golden tests and `spaceslab profile map <name>` |
| `ProfileMap/InstalledApps.swift` | list .app bundles in given folders (bundle id, name, path), dedupe by bundle id |

App target (`Sources/WindowsManagerApp/ProfileStudio/`), each view thin over a model:

| File | Responsibility |
| --- | --- |
| `ProfileStudioWindowController.swift` | window lifecycle, close prompt when dirty |
| `ProfileStudioModel.swift` | selection, mode, load/save via `ProfileStore`, compare state (preview task), zoom |
| `ProfileStudioView.swift` | split layout, sidebar, toolbar, empty/error states |
| `ProfileMapCanvas.swift` | draws `ProfileMapLayout` (monitors, windows, badges); drop and drag hooks are closures |
| `SpaceStripView.swift`, `WindowTileView.swift`, `MapLegendView.swift` | pieces of the canvas |
| `MapInspectorView.swift` | details card (View) and window editor fields (Edit) |
| `RestorePreviewSheet.swift` | B3 |
| `ProfileBuilderModel.swift` | draft, `EditHistory`, library data (running, installed, in profile), drop/drag handlers calling `ProfileDraftEditor` and `MapSnapping` |
| `AppLibraryView.swift` | library list, search, context menus, draggable rows |
| `ProfileOptionsPanel.swift`, `LaunchOrderEditor.swift` | Options and Launch order tabs |
| `StudioSaveSheet.swift` | start-point sheet (B2 step 1) and save/discard prompt |

Reused as is: `DisplayMap` (match, mapFrame), `LayoutStore`/`Layout`, `RestorePlanner`, `WindowMatcher`,
`ProfileTransfer.uniqueName`, `AppState.run`. Moved idea, not code: `MonitorsSettingsTab` arrangement math
and `LayoutEditorView` `EdgeHandle`/`CursorHold` (copied into `WindowTileView.swift`; the layout editor is not
touched).

---

## E. Phased delivery

Rules for every task: only the listed files; `swift build` and `swift test` green; no live Space switching or
app launching in tests (engine runs against the existing fake `RestoreEnvironment`); code comments follow the
repo style. "Model" = suggested worker model.

| ID | Title | Files (strict) | Depends | Model | Size |
| --- | --- | --- | --- | --- | --- |
| PM1 | Model: LaunchPlan, origin, addMissingDesktops | `WMCore/Profiles/LaunchPlan.swift` (new), `WMCore/Profiles/Profile.swift`, `Tests/WMCoreTests/ProfileLaunchPlanModelTests.swift` (new) | - | sonnet | 250 |
| PM2 | Space index and map layout math | `ProfileMap/ProfileSpaceIndex.swift`, `ProfileMap/ProfileMapLayout.swift`, `Tests/WMCoreTests/ProfileMapLayoutTests.swift` | - | sonnet | 380 |
| PM3 | Live status from a RestorePlan | `ProfileMap/ProfileLiveStatus.swift`, `Tests/WMCoreTests/ProfileLiveStatusTests.swift` | - | sonnet | 250 |
| PM4 | Installed apps catalog | `ProfileMap/InstalledApps.swift`, `Tests/WMCoreTests/InstalledAppsTests.swift` | - | haiku | 120 |
| PM5 | Launch sequence logic | `ProfileMap/LaunchSequence.swift`, `Tests/WMCoreTests/LaunchSequenceTests.swift` | PM1 | sonnet | 250 |
| PM6 | Draft editor, undo history, draft check | `ProfileMap/ProfileDraftEditor.swift`, `ProfileMap/EditHistory.swift`, `ProfileMap/ProfileDraftCheck.swift`, `Tests/WMCoreTests/ProfileDraftEditorTests.swift` | PM1 | sonnet | 400 |
| PM7 | Map snapping | `ProfileMap/MapSnapping.swift`, `Tests/WMCoreTests/MapSnappingTests.swift` | PM2 | haiku | 180 |
| PM8 | ASCII map renderer + golden tests | `ProfileMap/ProfileMapText.swift`, `Tests/WMCoreTests/ProfileMapTextTests.swift` | PM2 | haiku | 160 |
| EN1 | Planner + engine: ordered/sequential launch, launch-only apps, per-profile add Desktops, `preview` | `Restore/RestorePlan.swift`, `Restore/RestoreEngine.swift`, `Tests/WMCoreTests/RestoreLaunchSequenceTests.swift` | PM1, PM5 | sonnet (high effort; opus review) | 350 |
| UI1 | Studio window shell, entry points, empty/error states | `ProfileStudio/ProfileStudioWindowController.swift`, `ProfileStudioModel.swift`, `ProfileStudioView.swift`, `MenuBarContent.swift`, `Settings/ProfilesSettingsTab.swift` | - | sonnet | 350 |
| UI2 | Map canvas (read only drawing, a11y, zoom) | `ProfileStudio/ProfileMapCanvas.swift`, `SpaceStripView.swift`, `WindowTileView.swift`, `MapLegendView.swift` | PM2 | sonnet | 400 |
| UI3 | Viewer: inspector, compare overlay, preview sheet, Run | `ProfileStudio/MapInspectorView.swift`, `RestorePreviewSheet.swift`, `ProfileStudioModel.swift` (compare section only) | UI1, UI2, PM3, EN1 | sonnet | 350 |
| UI4 | Builder model and start sheet | `ProfileStudio/ProfileBuilderModel.swift`, `StudioSaveSheet.swift` | PM4, PM6, PM7 | sonnet | 380 |
| UI5 | Builder canvas interactions + library | `ProfileStudio/AppLibraryView.swift`, `ProfileStudio/BuilderCanvasOverlay.swift` (drop targets, drag/resize handles, zone highlight) | UI2, UI4 | sonnet | 380 |
| UI6 | Options and Launch order tabs | `ProfileStudio/ProfileOptionsPanel.swift`, `ProfileStudio/LaunchOrderEditor.swift` | UI4, PM5 | sonnet | 330 |
| UI7 | Wire Edit mode into the Studio (toolbar, step bar, save, undo keys) | `ProfileStudio/ProfileStudioView.swift`, `ProfileStudio/ProfileStudioModel.swift` | UI3, UI5, UI6 | sonnet | 250 |
| DOC1 | User guide section + spaceslab `profile map` | `docs/USER-GUIDE.md`, `Sources/spaceslab/Commands/ProfileMapCommand.swift` (new), `Sources/spaceslab/main.swift` (register only) | PM8, UI7 | haiku | 120 |

Paths: `ProfileMap/` = `Sources/WMCore/ProfileMap/`, `ProfileStudio/` = `Sources/WindowsManagerApp/ProfileStudio/`.

Dependency graph and parallel waves (max 4 at once, disjoint files):

```
Wave 1:  PM1   PM2   PM3   PM4        UI1 can start here too (no WMCore deps) -> run as 4: PM1 PM2 PM3 UI1, then PM4
Wave 2:  PM5(PM1)  PM6(PM1)  PM7(PM2)  PM8(PM2)
Wave 3:  EN1(PM1,PM5)   UI2(PM2)   UI4(PM4,PM6,PM7)
Wave 4:  UI3(UI1,UI2,PM3,EN1)   UI5(UI2,UI4)   UI6(UI4,PM5)
Wave 5:  UI7(UI3,UI5,UI6)  ->  DOC1
```

Conflict notes: `ProfileStudioModel.swift` is touched by UI1, UI3 (compare section) and UI7 (edit mode), never
in the same wave. `ProfilesSettingsTab.swift` and `MenuBarContent.swift` only in UI1.

Acceptance and tests per task:

- **PM1**: old fixture profiles (from `ProfileStoreTests`) decode; encode(decode(old)) is byte-identical;
  round trip of a profile with every new field; clamping of `delayAfter`/`timeout`; unknown `wait` value
  fails with a readable error.
- **PM2**: two monitors side by side / stacked / different heights keep relative arrangement; tiny monitor
  gets min size; zoom 0.5/2.0 scales; window rect for relativeFrame (0.5,0,0.5,1) lands in the right half of
  the content rect; hitTest returns topmost by zIndex; Split View Space yields two halves; all-Desktops window
  appears on every Desktop; minimized goes to tray; default Space selection rule.
- **PM3**: fixture plans: matched window with no steps -> inPlace; setFrame/moveToDesktop -> willMove;
  launch + unmatched "will be launched" -> willLaunch; unmatched other reasons -> notFound(reason);
  `restore == false` -> notRestored; missingDesktops -> Space status; summary counts.
- **PM4**: temp folder with fake `.app` bundles (Info.plist only) lists name/bundle id, ignores non-apps,
  dedupes, sorted by name.
- **PM5**: order = enabled items then rest; disabled excluded; requests carry `minWindows` (windows: count of
  restorable snapshots; appReady: 0; withoutWindows: 0) and timeout; validation messages (duplicate app,
  not installed, delay ignored in parallel mode); worst-case duration.
- **PM6**: add/delete/move Desktop renumbers `desktopNumber`, `position` and window `placement`; deleting a
  Desktop moves windows to the chosen Desktop; full-screen add/reorder keeps owner ids; result always passes
  `Profile.validate()`; history undo/redo/cap/coalescing.
- **PM7**: point inside a zone snaps to its rect; Option disables; edge snap within threshold; default
  placement clamps inside the monitor.
- **PM8**: golden strings for 1-monitor, 2-monitor and full-screen fixtures (this is how map geometry is
  "seen" without launching the app).
- **EN1** (fake environment): sequential mode launches one at a time in order, sleeps `delayAfter` except
  after `alreadyRunning`, cancellation between apps skips the rest; parallel/nil keeps today's results
  (existing `RestoreEngineTests` unchanged and green); launch-only app gets a launch step with 0 windows and
  is not hidden by `otherApps: .hide`; per-profile `addMissingDesktops` plans `addDesktop`; `preview` makes
  no environment calls besides `scan`.
- **UI1-UI7**: `swift build` green; no `@State`/`#Preview`; manual checklist in the PR description (open from
  menu bar and Settings; light/dark; VoiceOver reads a window tile; keyboard-only: place a window, reorder
  launch order, save; Reduce Motion on; disconnected-monitor profile; empty state). UI logic that grows
  beyond view glue must move into a WMCore file and get a test.
- **DOC1**: guide section "Profile Studio" with Map, Compare, Edit, Launch order; `spaceslab profile map Work`
  prints the PM8 rendering.

---

## F. Open questions (with the defaults taken) and top risks

| Question | Default decided |
| --- | --- |
| Show live window thumbnails (screenshots) on the map? | No. Needs Screen Recording and goes stale; icons + titles only. |
| Can the Builder create extra windows of a running app (Cmd+N)? | No. Planned windows beyond what the app opens are warned about and placed only when they exist. Revisit with per-app "new window" recipes later. |
| Documents/URLs per planned window? | Not in this plan; `documentPath` stays capture-only (ContentRestorer handles captured ones). |
| Stage Manager as a restore option? | No; shown as saved state and warning only. |
| Launch mode default when a launch order is first edited | Sequential. Profiles never edited keep `launchPlan == nil` (parallel, today). |
| Editing captured windows | Allowed (move, resize, Space, restore toggle); they keep `origin` nil and their title match. |
| Re-capture into an existing profile ("update from current")? | Later task; the Builder's "Start from current workspace" covers new profiles. |
| One Space per monitor on the canvas vs all Spaces at once | One selected Space per monitor plus strip; an "All Spaces" grid can come later. |
| Persist zoom and last selected Space | Per Studio session only (UserDefaults for window frame only). |

Top 5 risks:

1. **Sequential launch slows restores and hides failures**: worst case adds every timeout. Mitigation: UI
   estimate, per-step progress in the menu status, cancel between apps, default stays parallel.
2. **Planned windows that never appear**: apps open fewer windows than planned, so maps look "not found" after
   a correct restore. Mitigation: Builder warning per app, Compare shows the reason text, `appReady` wait mode.
3. **Coordinate mismatches** between display frame, visible frame, zone rects and canvas (top-left global,
   negative origins on left/upper monitors). Mitigation: all math in `ProfileMapLayout`/`MapSnapping` with
   tests on negative-origin fixtures; zones applied on the visible frame like `SnapController`.
4. **Compare cost and staleness**: a scan reads every window over AX (can take seconds with many apps).
   Mitigation: opt-in toggle, off main thread, cancel the previous preview task, refresh only on key/Cmd+R,
   timestamp "compared 14:05".
5. **Schema drift with older builds**: an older build re-saving a profile drops `launchPlan`/`origin`.
   Mitigation: optional keys only, byte-identical re-encode test, release note; bump schema only if a field
   ever changes meaning.
