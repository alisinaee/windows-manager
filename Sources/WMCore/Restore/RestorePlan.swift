import CoreGraphics
import Foundation

// The restore planner (phase P2.8): turns "what the profile says" and "what exists now" into an ordered list of
// steps. Everything here is pure: no system calls, so the whole plan can be tested with fixtures and printed
// for a dry run. `RestoreEngine` runs the steps.
//
// Inputs: the profile, a `WorkspaceScan` (live monitors, Spaces, windows), the saved-monitor -> live-monitor map
// (`DisplayMap.match`) and the window `MatchResult` (made by `WindowMatcher` from the *remapped* snapshots, see
// `RestorePlanner.remap`). Frames in a plan are already mapped onto the live monitors.
//
// Phases, in the order they run (a step per window or app):
//  1. launch          apps that have restorable snapshots but show no window (run by the engine before it plans again)
//  2. exitFullScreen  live window is full screen, snapshot is not
//  3. unminimize      live window is minimized, snapshot is not
//  4. moveToDesktop   snapshot Desktop N differs from the live Desktop
//  5. setFrame        every non-full-screen snapshot that is not within 2 pt already
//  6. enterFullScreen snapshot is full screen, live window is not; per monitor in saved Space order
//  7. minimize        snapshot is minimized
//  8. raise           back to front by zIndex, only windows that end up on a visible Desktop
//  9. otherApps       hide (or ask to quit) running apps that are not in the profile

/// The phases of a restore, in execution order.
public enum RestorePhase: String, Codable, CaseIterable, Comparable, Sendable {
    case launch
    case exitFullScreen
    case unminimize
    case moveToDesktop
    case setFrame
    case enterFullScreen
    case minimize
    case raise
    case otherApps

    /// Position in `allCases`.
    public var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: RestorePhase, rhs: RestorePhase) -> Bool { lhs.order < rhs.order }

    /// A short name for people.
    public var title: String {
        switch self {
        case .launch: return "Launch apps"
        case .exitFullScreen: return "Leave full screen"
        case .unminimize: return "Unminimize"
        case .moveToDesktop: return "Move to Desktop"
        case .setFrame: return "Place windows"
        case .enterFullScreen: return "Enter full screen"
        case .minimize: return "Minimize"
        case .raise: return "Restack"
        case .otherApps: return "Other apps"
        }
    }
}

/// The saved window and the live window a step works on.
public struct RestoreTarget: Hashable, Codable, Sendable {
    /// `WindowSnapshot.id`.
    public var snapshotID: UUID
    /// `LiveWindow.windowID`.
    public var windowID: UInt32
    public var pid: Int32
    public var app: AppRef
    /// The live title when known, else the saved one.
    public var title: String?

    public init(snapshotID: UUID, windowID: UInt32, pid: Int32, app: AppRef, title: String?) {
        self.snapshotID = snapshotID
        self.windowID = windowID
        self.pid = pid
        self.app = app
        self.title = title
    }

    public init(snapshot: WindowSnapshot, live: LiveWindow) {
        self.init(snapshotID: snapshot.id, windowID: live.windowID, pid: live.pid, app: snapshot.app,
                  title: live.title ?? snapshot.title)
    }

    /// `Google Chrome "Inbox" (window 84)`.
    public var label: String {
        let quoted = title.flatMap { $0.isEmpty ? nil : RestoreFormat.shorten($0, 40) }.map { " \"\($0)\"" } ?? ""
        return "\(app.name)\(quoted) (window \(windowID))"
    }
}

/// One thing the engine does. The associated values are everything the engine needs, so a step is
/// self-contained and can be logged, saved in a report or shown in a dry run.
public enum RestoreStep: Equatable, Sendable, CustomStringConvertible {
    /// Open an app and wait for `windowCount` windows.
    case launch(app: AppRef, windowCount: Int)
    case exitFullScreen(RestoreTarget)
    case unminimize(RestoreTarget)
    /// Move the window to the Desktop with this Space id. `desktop` is the 1-based "Desktop N" on the display
    /// `displayName`; `from` is the Desktop it is on now, when known, and `fromDisplayName` the display it is
    /// on now when that is another one.
    case moveToDesktop(RestoreTarget, desktop: Int, spaceID: UInt64, displayName: String, from: Int?,
                       fromDisplayName: String?)
    /// Put the window at `frame` (global top-left, already mapped onto the live display). `from` is where it
    /// is now. `beforeFullScreen` marks a move whose only job is to put the window on the right monitor
    /// before it enters full screen.
    case setFrame(RestoreTarget, frame: CGRect, from: CGRect, beforeFullScreen: Bool)
    /// Enter full screen on the display `displayUUID`. `spacePosition` is the saved 0-based Space position.
    case enterFullScreen(RestoreTarget, displayUUID: String, displayName: String, spacePosition: Int?)
    case minimize(RestoreTarget)
    /// Bring the window to the front of its app and the app to the front. `zIndex` is the saved stacking order.
    case raise(RestoreTarget, zIndex: Int)
    case hideApp(app: AppRef, pid: Int32)
    /// The profile asks to quit this app; the engine never does that on its own, the UI has to confirm.
    case needsConfirmationQuit(app: AppRef, pid: Int32)

    public var phase: RestorePhase {
        switch self {
        case .launch: return .launch
        case .exitFullScreen: return .exitFullScreen
        case .unminimize: return .unminimize
        case .moveToDesktop: return .moveToDesktop
        case .setFrame: return .setFrame
        case .enterFullScreen: return .enterFullScreen
        case .minimize: return .minimize
        case .raise: return .raise
        case .hideApp, .needsConfirmationQuit: return .otherApps
        }
    }

    /// The window a step works on; nil for app-level steps.
    public var target: RestoreTarget? {
        switch self {
        case .exitFullScreen(let t), .unminimize(let t), .minimize(let t): return t
        case .moveToDesktop(let t, _, _, _, _, _): return t
        case .setFrame(let t, _, _, _): return t
        case .enterFullScreen(let t, _, _, _): return t
        case .raise(let t, _): return t
        case .launch, .hideApp, .needsConfirmationQuit: return nil
        }
    }

    /// The app a step is about.
    public var app: AppRef {
        switch self {
        case .launch(let app, _), .hideApp(let app, _), .needsConfirmationQuit(let app, _): return app
        default: return target?.app ?? AppRef(bundleID: nil, name: "?")
        }
    }

    public var isLaunch: Bool { if case .launch = self { return true } else { return false } }

    /// One line for logs, progress and dry-run output.
    public var description: String {
        switch self {
        case .launch(let app, let count):
            return "launch \(app.name) (\(count) window\(count == 1 ? "" : "s"))"
        case .exitFullScreen(let t):
            return "leave full screen: \(t.label)"
        case .unminimize(let t):
            return "unminimize: \(t.label)"
        case .moveToDesktop(let t, let desktop, _, let display, let from, let fromDisplay):
            let place = fromDisplay.map { " of \($0)" } ?? ""
            let source = from.map { " (now on Desktop \($0)\(place))" } ?? ""
            return "move to Desktop \(desktop) on \(display)\(source): \(t.label)"
        case .setFrame(let t, let frame, let from, let beforeFullScreen):
            let why = beforeFullScreen ? " (to the right monitor, before full screen)" : ""
            return "set frame \(RestoreFormat.rect(frame)) (now \(RestoreFormat.rect(from)))\(why): \(t.label)"
        case .enterFullScreen(let t, _, let display, let position):
            let space = position.map { ", Space \($0 + 1)" } ?? ""
            return "enter full screen on \(display)\(space): \(t.label)"
        case .minimize(let t):
            return "minimize: \(t.label)"
        case .raise(let t, let z):
            return "raise (stacking \(z)): \(t.label)"
        case .hideApp(let app, _):
            return "hide \(app.name)"
        case .needsConfirmationQuit(let app, _):
            return "quit \(app.name) (needs confirmation)"
        }
    }
}

/// A saved window that has no live window to restore into.
public struct UnmatchedSnapshot: Hashable, Codable, Sendable {
    public var snapshotID: UUID
    public var app: AppRef
    public var title: String?
    /// Why nothing was found, for people.
    public var reason: String

    public init(snapshotID: UUID, app: AppRef, title: String?, reason: String) {
        self.snapshotID = snapshotID
        self.app = app
        self.title = title
        self.reason = reason
    }

    /// `Google Chrome "Inbox"`.
    public var label: String {
        let quoted = title.flatMap { $0.isEmpty ? nil : RestoreFormat.shorten($0, 40) }.map { " \"\($0)\"" } ?? ""
        return "\(app.name)\(quoted)"
    }
}

/// A Desktop the profile needs that does not exist on the live monitor. Adding Desktops is a later task (P3.2).
public struct MissingDesktop: Hashable, Codable, Sendable {
    /// 1-based "Desktop N".
    public var number: Int
    public var displayUUID: String
    public var displayName: String
    /// How many Desktops the live monitor has.
    public var available: Int
    public var snapshotIDs: [UUID]

    public init(number: Int, displayUUID: String, displayName: String, available: Int, snapshotIDs: [UUID]) {
        self.number = number
        self.displayUUID = displayUUID
        self.displayName = displayName
        self.available = available
        self.snapshotIDs = snapshotIDs
    }
}

/// The ordered steps of one restore, with everything a person should know before it runs.
public struct RestorePlan: Equatable, Sendable {
    public var profileName: String
    /// All steps in execution order: grouped by phase, phases in `RestorePhase.allCases` order.
    public var steps: [RestoreStep]
    /// Things worth reading: a Desktop is missing, a match is ambiguous, Accessibility is off, ...
    public var warnings: [String]
    /// Saved windows without a live window.
    public var unmatched: [UnmatchedSnapshot]
    /// `WindowSnapshot.id` of matches that were close to a coin flip.
    public var ambiguous: [UUID]
    public var missingDesktops: [MissingDesktop]

    public init(profileName: String, steps: [RestoreStep] = [], warnings: [String] = [],
                unmatched: [UnmatchedSnapshot] = [], ambiguous: [UUID] = [], missingDesktops: [MissingDesktop] = []) {
        self.profileName = profileName
        self.steps = steps
        self.warnings = warnings
        self.unmatched = unmatched
        self.ambiguous = ambiguous
        self.missingDesktops = missingDesktops
    }

    public var isEmpty: Bool { steps.isEmpty }

    public func steps(in phase: RestorePhase) -> [RestoreStep] { steps.filter { $0.phase == phase } }

    /// Phases that have at least one step, in order.
    public var phases: [RestorePhase] { RestorePhase.allCases.filter { phase in steps.contains { $0.phase == phase } } }

    /// The same plan without the steps of one phase (the engine drops `launch` after it has run).
    public func removing(_ phase: RestorePhase) -> RestorePlan {
        var copy = self
        copy.steps.removeAll { $0.phase == phase }
        return copy
    }

    /// The plan as text for a dry run: warnings, then the steps grouped by phase, then what was not found.
    public var outline: String {
        var lines: [String] = []
        lines.append("Restore plan for \"\(profileName)\": \(steps.count) step\(steps.count == 1 ? "" : "s")")
        if !warnings.isEmpty {
            lines.append("")
            lines.append("Warnings (\(warnings.count)):")
            for warning in warnings { lines.append("  - \(warning)") }
        }
        var number = 0
        for phase in phases {
            let group = steps(in: phase)
            lines.append("")
            lines.append("\(phase.title) (\(group.count)):")
            for step in group {
                number += 1
                lines.append("  \(number). \(step.description)")
            }
        }
        if steps.isEmpty {
            lines.append("")
            lines.append("Nothing to do: every matched window is already where the profile says.")
        }
        if !unmatched.isEmpty {
            lines.append("")
            lines.append("Not found (\(unmatched.count)):")
            for item in unmatched { lines.append("  - \(item.label): \(item.reason)") }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Planner

public enum RestorePlanner {
    /// Frames this close (points) to the saved frame count as already placed.
    public static let frameTolerance: CGFloat = 2

    /// Apps that are never hidden or quit by "other apps", on top of `WorkspaceScanner.isExcludedApp`
    /// (lower-case bundle ids): system agents and overlays, and Windows Manager itself.
    static let protectedBundleIDs: Set<String> = [
        WorkspaceScanner.ownBundleID.lowercased(), "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.windowmanager",
        "com.apple.spotlight", "com.apple.universalcontrol", "com.apple.screensaver.engine",
        "com.apple.accessibility.universalaccessauthwarn", "com.apple.usernotificationcenter",
        "com.apple.airplayuiagent", "com.apple.coreservices.uiagent", "com.apple.securityagent",
        "com.apple.screencaptureui", "com.apple.talagent",
    ]

    /// Maps every snapshot onto the live monitor its saved monitor was matched with: `displayUUID` becomes the
    /// live display's uuid and `frame` goes through `DisplayMap.mapFrame` (so it lies inside the live visible
    /// frame). Snapshots whose saved monitor has no match stay as they are. Use the result for
    /// `WindowMatcher.match`, so the matcher compares against where the windows should be now.
    public static func remap(_ snapshots: [WindowSnapshot], savedDisplays: [DisplayIdentity],
                             displayMatch: [String: DisplayIdentity]) -> [WindowSnapshot] {
        snapshots.map { snapshot in
            guard let saved = savedDisplays.first(where: { sameUUID($0.uuid, snapshot.displayUUID) }),
                  let live = displayMatch[saved.uuid]
                    ?? displayMatch.first(where: { sameUUID($0.key, saved.uuid) })?.value else { return snapshot }
            var mapped = snapshot
            mapped.frame = DisplayMap.mapFrame(snapshot.frame, from: saved, to: live)
            mapped.displayUUID = live.uuid
            return mapped
        }
    }

    /// Builds the plan. Pure: the same inputs always give the same plan.
    /// - Parameters:
    ///   - profile: the saved workspace (original frames and monitors).
    ///   - scan: what exists now.
    ///   - displayMatch: `DisplayMap.match(saved: profile.displays, current: scan.displays)`.
    ///   - match: `WindowMatcher.match` of `remap(profile.windows, ...)` against `scan.windows`.
    ///   - options: the switches to obey (normally `profile.options`).
    public static func plan(profile: Profile, scan: WorkspaceScan, displayMatch: [String: DisplayIdentity],
                            match: MatchResult, options: ProfileOptions) -> RestorePlan {
        var plan = RestorePlan(profileName: profile.name)
        plan.ambiguous = match.ambiguous

        let snapshots = remap(profile.windows, savedDisplays: profile.displays, displayMatch: displayMatch)
        let snapshotByID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let liveByID = Dictionary(scan.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })

        // Warnings about the setup itself.
        if scan.screenIsLocked {
            plan.warnings.append("The screen is locked, so windows cannot be moved.")
        } else if !scan.accessibilityTrusted {
            plan.warnings.append("Accessibility access is not granted, so windows cannot be moved.")
        }
        plan.warnings.append(contentsOf: displayWarnings(profile: profile, scan: scan, displayMatch: displayMatch))

        // Matched windows, in snapshot order.
        var items: [Item] = []
        for (order, found) in match.matched.enumerated() {
            guard let snapshot = snapshotByID[found.snapshotID], let live = liveByID[found.windowID] else {
                plan.warnings.append("A match points at a window that is no longer there (window \(found.windowID)); it was skipped.")
                continue
            }
            items.append(Item(snapshot: snapshot, live: live,
                              target: RestoreTarget(snapshot: snapshot, live: live),
                              display: liveDisplay(for: snapshot, in: scan), order: order))
        }

        for id in match.ambiguous {
            if let item = items.first(where: { $0.snapshot.id == id }) {
                plan.warnings.append("The match for \(item.target.label) is ambiguous: another window fitted about as well.")
            }
        }

        // Launch + unmatched.
        planLaunch(profile: profile, scan: scan, match: match, options: options, into: &plan)

        // Window phases.
        var exitFullScreen: [RestoreStep] = []
        var unminimize: [RestoreStep] = []
        var moveToDesktop: [RestoreStep] = []
        var setFrame: [RestoreStep] = []
        var minimize: [RestoreStep] = []
        var movedTo: [UUID: UInt64] = [:]
        var enter: [(item: Item, position: Int?)] = []
        var missing: [String: MissingDesktop] = [:]
        var skippedFullScreen = 0

        for item in items {
            let snapshot = item.snapshot, live = item.live, target = item.target
            let wantsFullScreen = snapshot.isFullScreen && !snapshot.isMinimized

            // 1. Leave full screen. Needed to place a window that should not be full screen.
            if live.isFullScreen && !wantsFullScreen {
                exitFullScreen.append(.exitFullScreen(target))
            }

            // 2. Unminimize.
            if live.isMinimized && !snapshot.isMinimized {
                unminimize.append(.unminimize(target))
            }

            // 3. Desktop.
            if options.restoreSpaces, !wantsFullScreen, case .desktop(let number) = snapshot.placement,
               let display = item.display {
                switch desktop(number, on: display, in: scan) {
                case .found(let space):
                    if !live.spaceIDs.contains(space.id) {
                        var from: Int?
                        if case .desktop(let current) = WorkspaceScanner.placement(for: live, in: scan) { from = current }
                        var fromDisplay: String?
                        if let uuid = live.displayUUID, !sameUUID(uuid, display.uuid) {
                            fromDisplay = scan.display(withUUID: uuid)?.name
                        }
                        moveToDesktop.append(.moveToDesktop(target, desktop: number, spaceID: space.id,
                                                            displayName: display.name, from: from,
                                                            fromDisplayName: fromDisplay))
                        movedTo[snapshot.id] = space.id
                    }
                case .missing(let available):
                    let key = "\(display.uuid)#\(number)"
                    var entry = missing[key] ?? MissingDesktop(number: number, displayUUID: display.uuid,
                                                               displayName: display.name, available: available,
                                                               snapshotIDs: [])
                    entry.snapshotIDs.append(snapshot.id)
                    missing[key] = entry
                case .unknown:
                    plan.warnings.append("The Spaces of \(display.name) are unknown, so \(target.label) stays on its Desktop.")
                }
            }
            if options.restoreSpaces, snapshot.placement == .allDesktops, live.spaceIDs.count <= 1,
               !wantsFullScreen {
                plan.warnings.append("\(target.label) was assigned to all Desktops; that setting is not restored.")
            }

            // 4. Frame.
            if wantsFullScreen {
                if !options.restoreFullScreen {
                    skippedFullScreen += 1
                } else if !live.isFullScreen {
                    // Full screen opens on the monitor the window is on, so move it there first.
                    if let display = item.display, !live.isOnDisplay(display) {
                        setFrame.append(.setFrame(target, frame: snapshot.frame, from: live.frame, beforeFullScreen: true))
                    }
                    enter.append((item, position: fullScreenPosition(snapshot)))
                    if let space = profile.spaces.first(where: { $0.fullScreenWindowIDs.contains(snapshot.id) }),
                       space.isSplitView {
                        plan.warnings.append("\(target.label) was in Split View; it will enter full screen on its own.")
                    }
                }
            } else if !(snapshot.isMinimized && live.isMinimized) {
                // A window that leaves full screen keeps the screen-sized frame until it is set again.
                let inPlace = WindowMover.frameMatches(live.frame, snapshot.frame, tolerance: frameTolerance)
                if live.isFullScreen || !inPlace {
                    setFrame.append(.setFrame(target, frame: snapshot.frame, from: live.frame, beforeFullScreen: false))
                }
            }

            // 6. Minimize.
            if snapshot.isMinimized && !live.isMinimized && !wantsFullScreen {
                minimize.append(.minimize(target))
            }
        }

        // 5. Full screen: per monitor in saved Space order, one at a time.
        let displayOrder = Dictionary(scan.displays.enumerated().map { ($1.uuid.uppercased(), $0) },
                                      uniquingKeysWith: { first, _ in first })
        let entered = enter.sorted { a, b in
            let da = a.item.display.flatMap { displayOrder[$0.uuid.uppercased()] } ?? Int.max
            let db = b.item.display.flatMap { displayOrder[$0.uuid.uppercased()] } ?? Int.max
            if da != db { return da < db }
            let pa = a.position ?? Int.max, pb = b.position ?? Int.max
            if pa != pb { return pa < pb }
            return (a.item.snapshot.zIndex, a.item.order) < (b.item.snapshot.zIndex, b.item.order)
        }
        let enterFullScreen: [RestoreStep] = entered.map { entry in
            .enterFullScreen(entry.item.target, displayUUID: entry.item.display?.uuid ?? entry.item.snapshot.displayUUID,
                             displayName: entry.item.display?.name ?? "its display", spacePosition: entry.position)
        }
        let enteringIDs = Set(entered.map { $0.item.snapshot.id })

        if skippedFullScreen > 0 {
            plan.warnings.append("\(skippedFullScreen) full-screen window\(skippedFullScreen == 1 ? " is" : "s are") left alone because restoring full screen is switched off.")
        }
        for entry in missing.values.sorted(by: { ($0.displayName, $0.number) < ($1.displayName, $1.number) }) {
            plan.missingDesktops.append(entry)
            let count = entry.snapshotIDs.count
            plan.warnings.append("missing Desktop \(entry.number) on \(entry.displayName) (it has \(entry.available)): "
                + "\(count) window\(count == 1 ? " stays" : "s stay") where \(count == 1 ? "it is" : "they are").")
        }

        // 7. Raise, back to front. Only windows that end up on a Desktop that is visible, because raising a
        // window on another Space makes macOS switch to it.
        let raisable = items.filter { item in
            let snapshot = item.snapshot
            guard !snapshot.isMinimized, !snapshot.isFullScreen, !enteringIDs.contains(snapshot.id) else { return false }
            return endsOnVisibleDesktop(item, movedTo: movedTo[snapshot.id], scan: scan)
        }
        let backToFront = raisable.sorted { (a: Item, b: Item) in
            (b.snapshot.zIndex, b.order) < (a.snapshot.zIndex, a.order)
        }
        // The window server lists windows front to back; when the raisable ones already follow the saved order
        // there is nothing to restack.
        let livePosition = Dictionary(scan.windows.enumerated().map { ($1.windowID, $0) },
                                      uniquingKeysWith: { first, _ in first })
        let frontToBack = Array(backToFront.reversed())
        let alreadyStacked = zip(frontToBack, frontToBack.dropFirst()).allSatisfy { front, back in
            (livePosition[front.live.windowID] ?? 0) < (livePosition[back.live.windowID] ?? 0)
        }
        let raise: [RestoreStep] = alreadyStacked ? [] : backToFront.map { .raise($0.target, zIndex: $0.snapshot.zIndex) }

        // 8. Other apps.
        let otherApps = planOtherApps(profile: profile, scan: scan, options: options)

        plan.steps = plan.steps(in: .launch) + exitFullScreen + unminimize + moveToDesktop + setFrame
            + enterFullScreen + minimize + raise + otherApps
        return plan
    }

    // MARK: Pieces

    private struct Item {
        /// Remapped onto the live monitors.
        var snapshot: WindowSnapshot
        var live: LiveWindow
        var target: RestoreTarget
        /// The live monitor the snapshot belongs on.
        var display: DisplayIdentity?
        /// Position in the match list.
        var order: Int
    }

    private enum DesktopLookup {
        case found(SpaceInfo)
        case missing(available: Int)
        case unknown
    }

    private static func sameUUID(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// The live monitor for a remapped snapshot: its `displayUUID`, else the main display.
    private static func liveDisplay(for snapshot: WindowSnapshot, in scan: WorkspaceScan) -> DisplayIdentity? {
        scan.display(withUUID: snapshot.displayUUID) ?? scan.displays.first(where: \.isMain) ?? scan.displays.first
    }

    private static func desktop(_ number: Int, on display: DisplayIdentity, in scan: WorkspaceScan) -> DesktopLookup {
        guard let list = scan.spaces(onDisplay: display.uuid) else { return .unknown }
        let desktops = list.desktops.sorted { $0.index < $1.index }
        guard number >= 1, number <= desktops.count else { return .missing(available: desktops.count) }
        return .found(desktops[number - 1])
    }

    private static func fullScreenPosition(_ snapshot: WindowSnapshot) -> Int? {
        if case .fullScreen(let position) = snapshot.placement { return position }
        return nil
    }

    private static func endsOnVisibleDesktop(_ item: Item, movedTo spaceID: UInt64?, scan: WorkspaceScan) -> Bool {
        if let spaceID {
            guard let uuid = item.display?.uuid, let list = scan.spaces(onDisplay: uuid) else { return false }
            return list.currentSpaceID == spaceID
        }
        if item.live.isFullScreen || item.live.isMinimized { return false }
        return item.live.isOnCurrentSpace
    }

    /// Warnings about monitors: a saved monitor lands on a different live one, or two share one.
    private static func displayWarnings(profile: Profile, scan: WorkspaceScan,
                                        displayMatch: [String: DisplayIdentity]) -> [String] {
        var warnings: [String] = []
        if scan.displays.isEmpty {
            warnings.append("No monitor was found; frames are used as saved.")
            return warnings
        }
        var users: [String: [String]] = [:]
        for saved in profile.displays {
            guard let live = displayMatch[saved.uuid] else { continue }
            users[live.uuid.uppercased(), default: []].append(saved.name)
            if !sameUUID(saved.uuid, live.uuid) {
                warnings.append("Saved monitor \"\(saved.name)\" is restored onto \"\(live.name)\".")
            }
        }
        for (_, names) in users.sorted(by: { $0.key < $1.key }) where names.count > 1 {
            warnings.append("Saved monitors \(names.map { "\"\($0)\"" }.joined(separator: " and ")) share one monitor now.")
        }
        return warnings
    }

    /// Launch steps and the list of saved windows that have nothing to restore into.
    private static func planLaunch(profile: Profile, scan: WorkspaceScan, match: MatchResult,
                                   options: ProfileOptions, into plan: inout RestorePlan) {
        var launchApps: [AppRef] = []
        for snapshot in match.missing {
            let hasWindows = scan.windows.contains { Profile.isSameApp($0.app, snapshot.app) }
            let reason: String
            if hasWindows {
                reason = "the app has fewer windows open than the profile"
            } else if options.launchMissingApps {
                reason = "the app is not running; it will be launched"
                if !launchApps.contains(where: { Profile.isSameApp($0, snapshot.app) }) { launchApps.append(snapshot.app) }
            } else {
                reason = "the app is not running and launching apps is switched off"
            }
            plan.unmatched.append(UnmatchedSnapshot(snapshotID: snapshot.id, app: snapshot.app,
                                                    title: snapshot.title, reason: reason))
        }
        for app in launchApps {
            let wanted = profile.windows.filter { $0.restore && Profile.isSameApp($0.app, app) }.count
            plan.steps.append(.launch(app: app, windowCount: max(wanted, 1)))
        }
    }

    private static func planOtherApps(profile: Profile, scan: WorkspaceScan, options: ProfileOptions) -> [RestoreStep] {
        guard options.otherApps != .leave else { return [] }
        let profileApps = profile.apps
        var seen = Set<Int32>()
        var steps: [RestoreStep] = []
        for window in scan.windows {
            if profileApps.contains(where: { Profile.isSameApp($0, window.app) }) { continue }
            if isProtected(window.app) { continue }
            guard window.pid > 0, seen.insert(window.pid).inserted else { continue }
            steps.append(options.otherApps == .hide
                ? .hideApp(app: window.app, pid: window.pid)
                : .needsConfirmationQuit(app: window.app, pid: window.pid))
        }
        return steps
    }

    /// System agents, overlays and Windows Manager itself are never hidden or quit.
    static func isProtected(_ app: AppRef) -> Bool {
        if WorkspaceScanner.isExcludedApp(name: app.name, bundleID: app.bundleID) { return true }
        guard let id = app.bundleID?.lowercased() else { return false }
        return protectedBundleIDs.contains(id)
    }
}

// MARK: - Helpers shared by the restore files

enum RestoreFormat {
    /// `1200x800 at 100,200`.
    static func rect(_ frame: CGRect) -> String {
        "\(Int(frame.width.rounded()))x\(Int(frame.height.rounded())) at \(Int(frame.minX.rounded())),\(Int(frame.minY.rounded()))"
    }

    static func shorten(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "\u{2026}" : flat
    }
}

private extension LiveWindow {
    /// True when the window's display is `display` (by uuid), or, when unknown, when most of it lies there.
    func isOnDisplay(_ display: DisplayIdentity) -> Bool {
        if let uuid = displayUUID { return uuid.caseInsensitiveCompare(display.uuid) == .orderedSame }
        return display.frame.intersects(frame)
    }
}
