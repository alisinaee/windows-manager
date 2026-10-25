import AppKit
import ApplicationServices
import Foundation

// Measures how macOS places native full-screen Spaces: capture windows up front, enter / exit full screen
// through one of three triggers, and watch SpaceReader until the change shows up.
//
// Technique credit: setting the AXFullScreen attribute and pressing menu items found through AXMenuBar are
// standard Accessibility techniques (Hammerspoon, MIT, offers both as hs.window:setFullScreen and
// hs.application:selectMenuItem). The SkyLight call signature follows the MIT-licensed yabai project
// (src/misc/extern.h). All code below is our own.

/// How full screen is triggered.
public enum FullScreenMethod: String, CaseIterable {
    /// Set the window's AXFullScreen attribute.
    case ax
    /// AXPress the app's "Enter Full Screen" / "Exit Full Screen" menu item.
    case menu
    /// Post Ctrl+Cmd+F key events to the app's pid.
    case keys
}

/// Where a new full-screen Space landed in its display's list.
public enum Placement: Equatable, Hashable, CustomStringConvertible {
    /// After every Space that existed before.
    case end
    /// Directly after the Desktop the window came from.
    case afterOrigin
    /// Directly after the Space that was current when full screen was triggered.
    case afterCurrent
    /// Somewhere else; the value is the 0-based index in the display's list (-1: the Space is not in the list).
    case other(Int)

    public var description: String {
        switch self {
        case .end: return "end"
        case .afterOrigin: return "after-origin"
        case .afterCurrent: return "after-current"
        case .other(let index): return "other(index \(index))"
        }
    }
}

/// What changed between two readings of one display's Space list.
public struct OrderDiff: Equatable {
    /// Spaces only in `after` (their `index` is the position in `after`).
    public var added: [SpaceInfo]
    /// Spaces only in `before` (their `index` is the position in `before`).
    public var removed: [SpaceInfo]
    /// Spaces present in both lists whose relative order changed; the smallest set that explains the change.
    public var movedIDs: [UInt64]
    public var currentBefore: UInt64
    public var currentAfter: UInt64

    public var reordered: Bool { !movedIDs.isEmpty }
    public var currentChanged: Bool { currentBefore != currentAfter }
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && !reordered && !currentChanged }
}

/// A full-screen related menu item found in an app's menu bar.
public struct FullScreenMenuItem {
    public var element: AXUIElement
    public var title: String
    /// Menu path such as "View > Enter Full Screen".
    public var path: String
    public var enabled: Bool
}

/// Raw SkyLight data of one full-screen Space that SpaceReader does not expose.
public struct RawFullScreenInfo: Equatable {
    public var spaceID: UInt64
    /// The `fromSpace` value macOS keeps for the Space (a Space uuid; may be empty), when present.
    public var fromSpace: String?
    /// Key names found on the Space entry and its tile entries ("tile.<key>"), to spot undocumented fields.
    public var keys: [String]
}

/// What a window exposes for full screen through Accessibility.
public struct AXFullScreenInfo: Equatable {
    public var readable: Bool
    public var value: Bool?
    public var settable: Bool
}

/// A window captured up front, with everything needed to act on it later even from another Space.
public struct FullScreenTarget {
    public var app: NSRunningApplication
    /// Stays usable after the user switches Space, even though AX stops listing the window there.
    public var element: AXUIElement
    public var pid: Int32
    public var appName: String
    public var bundleID: String?
    public var windowID: UInt32
    public var title: String
    public var subrole: String
    public var isMinimized: Bool
    public var isFullScreen: Bool
    public var isMain: Bool
    public var frame: CGRect?
    /// Space ids the window was on when it was captured.
    public var originSpaceIDs: [UInt64]

    public var label: String {
        "\(appName) window \(windowID)" + (title.isEmpty ? "" : " \"\(title)\"")
    }
}

/// The measured result of one enter or exit.
public struct FullScreenTransition {
    public enum Direction: String { case enter, exit }

    public var direction: Direction
    public var method: FullScreenMethod
    public var target: FullScreenTarget

    /// nil when everything worked; otherwise why it did not (precondition failed, trigger failed, timeout).
    public var error: String?
    /// The trigger was delivered (AX call succeeded, menu item pressed, keys posted).
    public var triggered = false
    public var triggerDetail = ""
    /// What the optional focus step did (menu / keys need the window to be the app's key window).
    public var focusNote: String?
    /// Enter: the window owns a full-screen Space. Exit: that Space is gone.
    public var succeeded = false
    /// Seconds from just before the trigger until `succeeded` showed up in SpaceReader.
    public var seconds: TimeInterval?
    /// Seconds until the trigger call itself returned.
    public var triggerCallSeconds: TimeInterval?
    /// Enter: seconds until a new full-screen Space first appeared in the list (it may not be linked to the window yet).
    public var appearedSeconds: TimeInterval?
    /// Exit: seconds until the window was reported on a Desktop again.
    public var returnedSeconds: TimeInterval?

    public var beforeAll: [DisplaySpaces] = []
    /// First reading in which `succeeded` was true (or the last reading when it never was).
    public var afterAll: [DisplaySpaces] = []
    /// Reading taken `settle` seconds later, after animations and any reordering.
    public var settledAll: [DisplaySpaces] = []
    public var displayIdentifier: String?

    /// Enter: the new Space. Exit: the full-screen Space that was left.
    public var fullScreenSpaceID: UInt64?
    /// Enter: the Desktop the window was on.
    public var originSpaceID: UInt64?
    /// Current Space of the display before the focus step, at the trigger, and after settling.
    public var currentBefore: UInt64?
    public var currentAtTrigger: UInt64?
    public var currentAfter: UInt64?
    /// "window id" or "pid": how the Space was matched to the window.
    public var matchedBy: String?

    public var placement: Placement?
    /// Every placement class that fits (ambiguous when the origin is also the current Space, or is the last Space).
    public var placementMatches: [Placement] = []
    public var placementSettled: Placement?

    /// macOS's own `fromSpace` for the full-screen Space and the Desktop it resolves to.
    public var fromSpaceUUID: String?
    public var fromSpaceID: UInt64?
    public var rawKeys: [String] = []

    /// Exit: the Desktop the window is on afterwards (first reading, and after settling).
    public var returnedSpaceID: UInt64?
    public var returnedSettledSpaceID: UInt64?

    public var axFullScreenAfter: Bool?

    public init(direction: Direction, method: FullScreenMethod, target: FullScreenTarget) {
        self.direction = direction
        self.method = method
        self.target = target
    }

    public func display(_ displays: [DisplaySpaces]) -> DisplaySpaces? {
        guard let id = displayIdentifier else { return nil }
        return displays.first { $0.displayIdentifier == id }
    }
}

public enum FullScreenProbe {
    public static let defaultTimeout: TimeInterval = 6
    public static let pollInterval: TimeInterval = 0.05
    /// Wait after success before the settled reading: covers the full-screen animation and Space reordering.
    public static let defaultSettle: TimeInterval = 0.8
    /// Virtual key code of "F" on ANSI keyboards.
    static let keyCodeF: CGKeyCode = 3

    // MARK: - Pure helpers

    /// Where the new Space `newSpaceID` sits in `after`, judged against the Spaces that already existed in `before`
    /// (Spaces that appeared meanwhile are ignored, so an unrelated new Space does not disturb the answer).
    /// Several classes can fit at once; the order of preference is afterOrigin, afterCurrent, end, other.
    public static func classifyPlacement(before: DisplaySpaces, after: DisplaySpaces, originSpaceID: UInt64?,
                                         currentSpaceID: UInt64?, newSpaceID: UInt64) -> Placement {
        placementMatches(before: before, after: after, originSpaceID: originSpaceID,
                         currentSpaceID: currentSpaceID, newSpaceID: newSpaceID)[0]
    }

    /// Every placement class that fits, in the order of preference; never empty.
    public static func placementMatches(before: DisplaySpaces, after: DisplaySpaces, originSpaceID: UInt64?,
                                        currentSpaceID: UInt64?, newSpaceID: UInt64) -> [Placement] {
        guard let newIndex = after.spaces.firstIndex(where: { $0.id == newSpaceID }) else { return [.other(-1)] }
        let known = Set(before.spaces.map(\.id))
        // The nearest Space on the left that existed before, and whether any old Space is on the right.
        let previous = after.spaces[..<newIndex].last { known.contains($0.id) }
        let oldSpaceOnRight = after.spaces[(newIndex + 1)...].contains { known.contains($0.id) }

        var matches: [Placement] = []
        if let origin = originSpaceID, previous?.id == origin { matches.append(.afterOrigin) }
        if let current = currentSpaceID, previous?.id == current { matches.append(.afterCurrent) }
        if !oldSpaceOnRight { matches.append(.end) }
        return matches.isEmpty ? [.other(newIndex)] : matches
    }

    /// Compares two readings of one display.
    public static func diffOrder(before: DisplaySpaces, after: DisplaySpaces) -> OrderDiff {
        let beforeIDs = Set(before.spaces.map(\.id))
        let afterIDs = Set(after.spaces.map(\.id))
        let keptBefore = before.spaces.map(\.id).filter { afterIDs.contains($0) }
        let keptAfter = after.spaces.map(\.id).filter { beforeIDs.contains($0) }
        let stayed = Set(longestCommonSubsequence(keptBefore, keptAfter))
        return OrderDiff(
            added: after.spaces.filter { !beforeIDs.contains($0.id) },
            removed: before.spaces.filter { !afterIDs.contains($0.id) },
            movedIDs: keptAfter.filter { !stayed.contains($0) },
            currentBefore: before.currentSpaceID,
            currentAfter: after.currentSpaceID
        )
    }

    /// `spaceIDs` that are on the display, sorted into the display's order.
    public static func order(of spaceIDs: [UInt64], in display: DisplaySpaces) -> [UInt64] {
        let wanted = Set(spaceIDs)
        return display.spaces.map(\.id).filter { wanted.contains($0) }
    }

    /// The full-screen Space a window owns: matched by window id, or, failing that, the only candidate
    /// Space of the same pid that is not in `excluding` (Spaces that were already there before entering).
    public static func ownedFullScreenSpace(windowID: UInt32, pid: Int32, in displays: [DisplaySpaces],
                                            excluding: Set<UInt64> = [])
        -> (display: DisplaySpaces, space: SpaceInfo, matchedBy: String)? {
        for display in displays {
            for space in display.spaces where space.kind == .fullscreen && space.fullScreenWindowIDs.contains(windowID) {
                return (display, space, "window id")
            }
        }
        var byPID: [(DisplaySpaces, SpaceInfo)] = []
        for display in displays {
            for space in display.spaces
            where space.kind == .fullscreen && !excluding.contains(space.id) && space.fullScreenOwnerPID == pid {
                byPID.append((display, space))
            }
        }
        if byPID.count == 1 { return (byPID[0].0, byPID[0].1, "pid") }
        return nil
    }

    /// The Space a window "lives on": among the ids it reports, a Desktop that is current on its display if
    /// there is one, otherwise the first Desktop, otherwise the first known Space of any kind.
    public static func homeSpace(ofWindowSpaces ids: [UInt64], in displays: [DisplaySpaces])
        -> (display: DisplaySpaces, space: SpaceInfo)? {
        var found: [(DisplaySpaces, SpaceInfo)] = []
        for display in displays {
            for space in display.spaces where ids.contains(space.id) { found.append((display, space)) }
        }
        let desktops = found.filter { $0.1.kind == .desktop }
        let pool = desktops.isEmpty ? found : desktops
        guard let pick = pool.first(where: { $0.1.isCurrent }) ?? pool.first else { return nil }
        return (pick.0, pick.1)
    }

    /// True when a menu item title is a full-screen item. `entering`: true accepts "Enter Full Screen" and plain
    /// toggles, false accepts "Exit Full Screen" and plain toggles, nil accepts any of them. English titles only.
    /// A whitelist, so items like "Always Show Toolbar in Full Screen" never match.
    public static func menuTitleMatches(_ title: String, entering: Bool?) -> Bool {
        var text = title.lowercased()
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let enters: Set<String> = ["enter full screen", "enter fullscreen", "enter full-screen"]
        let exits: Set<String> = ["exit full screen", "exit fullscreen", "exit full-screen",
                                  "leave full screen", "leave fullscreen"]
        let toggles: Set<String> = ["full screen", "fullscreen", "toggle full screen", "toggle fullscreen"]
        switch entering {
        case .some(true): return enters.contains(text) || toggles.contains(text)
        case .some(false): return exits.contains(text) || toggles.contains(text)
        case .none: return enters.contains(text) || exits.contains(text) || toggles.contains(text)
        }
    }

    /// Reads the raw `SLSCopyManagedDisplaySpaces` array for full-screen Spaces: their `fromSpace` value and key names.
    public static func parseRawFullScreen(_ raw: [[String: Any]]) -> [UInt64: RawFullScreenInfo] {
        var result: [UInt64: RawFullScreenInfo] = [:]
        for display in raw {
            for entry in (display["Spaces"] as? [[String: Any]]) ?? [] {
                guard (entry["type"] as? NSNumber)?.intValue == 4,
                      let id = ((entry["id64"] as? NSNumber) ?? (entry["ManagedSpaceID"] as? NSNumber))?.uint64Value
                else { continue }
                let tiles = ((entry["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]]) ?? []

                var keys = Set(entry.keys)
                var from: String?
                func take(_ value: Any?) {
                    guard from == nil, let value else { return }
                    if let text = value as? String { from = text } else if let number = value as? NSNumber { from = number.stringValue }
                }
                take(entry["fromSpace"])
                for tile in tiles {
                    for key in tile.keys { keys.insert("tile.\(key)") }
                    take(tile["fromSpace"])
                }
                result[id] = RawFullScreenInfo(spaceID: id, fromSpace: from, keys: keys.sorted())
            }
        }
        return result
    }

    /// The Desktop a `fromSpace` value points at: matched against Space uuids, then against Space ids.
    /// An empty value (or no match) falls back to the Desktop whose uuid is empty (the first Desktop of a display).
    public static func resolveFromSpace(_ value: String, in display: DisplaySpaces) -> SpaceInfo? {
        let desktops = display.spaces.filter { $0.kind == .desktop }
        if !value.isEmpty {
            if let hit = display.spaces.first(where: { $0.uuid.caseInsensitiveCompare(value) == .orderedSame && !$0.uuid.isEmpty }) {
                return hit
            }
            if let number = UInt64(value), let hit = display.spaces.first(where: { $0.id == number }) { return hit }
            return nil
        }
        return desktops.first { $0.uuid.isEmpty }
    }

    private static func longestCommonSubsequence(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [UInt64] = []
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                result.append(a[i])
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    // MARK: - Capturing windows

    /// Windows of the apps matching `appQuery` (name or bundle id) that AX lists right now, i.e. those on the
    /// current Space. The main window comes first. Run this before the user (or the test) changes Space.
    public static func capture(appQuery: String, titleContains: String? = nil,
                               standardWindowsOnly: Bool = true) -> [FullScreenTarget] {
        var apps = AXWindows.runningApps(matching: appQuery)
        let regular = apps.filter { $0.activationPolicy == .regular }
        if !regular.isEmpty { apps = regular }
        return capture(apps: apps, titleContains: titleContains, standardWindowsOnly: standardWindowsOnly)
    }

    public static func capture(apps: [NSRunningApplication], titleContains: String? = nil,
                               standardWindowsOnly: Bool = true) -> [FullScreenTarget] {
        var targets: [FullScreenTarget] = []
        for app in apps {
            for element in AXWindows.windows(of: app) {
                guard let windowID = AXWindows.windowID(of: element) else { continue }
                let title = AXWindows.title(of: element)
                if let needle = titleContains, !needle.isEmpty, !title.localizedCaseInsensitiveContains(needle) { continue }
                let subrole = AX.string(element, kAXSubroleAttribute) ?? ""
                if standardWindowsOnly && subrole != kAXStandardWindowSubrole { continue }
                targets.append(FullScreenTarget(
                    app: app, element: element, pid: app.processIdentifier,
                    appName: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                    bundleID: app.bundleIdentifier, windowID: windowID, title: title, subrole: subrole,
                    isMinimized: AXWindows.isMinimized(element), isFullScreen: AXWindows.isFullScreen(element),
                    isMain: AX.bool(element, kAXMainAttribute) ?? false, frame: AXWindows.frame(of: element),
                    originSpaceIDs: []))
            }
        }
        let spaces = SpaceReader.spaces(forWindows: targets.map(\.windowID))
        for i in targets.indices { targets[i].originSpaceIDs = spaces[targets[i].windowID] ?? [] }
        // Main windows first, otherwise keep AX order (front to back).
        return targets.enumerated()
            .sorted { a, b in
                if a.element.isMain != b.element.isMain { return a.element.isMain }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// What AX says about full screen for one window (read only).
    public static func axFullScreenInfo(of target: FullScreenTarget) -> AXFullScreenInfo {
        let value = AX.value(target.element, fullScreenAttribute)
        let bool = value.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? CFBooleanGetValue(unsafeDowncast($0, to: CFBoolean.self)) : nil }
        return AXFullScreenInfo(readable: value != nil, value: bool, settable: AX.isSettable(target.element, fullScreenAttribute))
    }

    /// Looks in the app's menu bar for a full-screen item (read only, nothing is opened or pressed).
    /// `entering` as in `menuTitleMatches`.
    public static func findFullScreenMenuItem(pid: Int32, entering: Bool?) -> FullScreenMenuItem? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 2.0)
        guard let bar = AX.element(appElement, kAXMenuBarAttribute) else { return nil }
        for top in AX.elements(bar, kAXChildrenAttribute) {
            let topTitle = AX.string(top, kAXTitleAttribute) ?? ""
            if topTitle == "Apple" { continue }
            if let hit = searchMenu(top, path: [topTitle], depth: 0, entering: entering) { return hit }
        }
        return nil
    }

    private static func searchMenu(_ element: AXUIElement, path: [String], depth: Int, entering: Bool?) -> FullScreenMenuItem? {
        guard depth < 4 else { return nil }
        for child in AX.elements(element, kAXChildrenAttribute) {
            let role = AX.string(child, kAXRoleAttribute)
            if role == kAXMenuRole {
                if let hit = searchMenu(child, path: path, depth: depth, entering: entering) { return hit }
            } else if role == kAXMenuItemRole {
                let title = AX.string(child, kAXTitleAttribute) ?? ""
                if title.isEmpty { continue }
                if menuTitleMatches(title, entering: entering) {
                    return FullScreenMenuItem(element: child, title: title, path: (path + [title]).joined(separator: " > "),
                                              enabled: AX.bool(child, kAXEnabledAttribute) ?? true)
                }
                if let hit = searchMenu(child, path: path + [title], depth: depth + 1, entering: entering) { return hit }
            }
        }
        return nil
    }

    // MARK: - Enter and exit

    /// Triggers full screen for `target` and waits (polling every 50 ms) until the window owns a full-screen Space.
    /// `focus`: bring the app and window to the front first; nil = yes for menu and keys (they act on the key
    /// window), no for ax. Never throws; problems are in `error`.
    public static func enter(_ target: FullScreenTarget, method: FullScreenMethod, focus: Bool? = nil,
                             timeout: TimeInterval = defaultTimeout, settle: TimeInterval = defaultSettle) -> FullScreenTransition {
        var t = FullScreenTransition(direction: .enter, method: method, target: target)
        guard AXPermission.isTrusted() else { t.error = "Accessibility is not trusted for this process"; return t }
        guard let before = try? SpaceReader.displays() else { t.error = "could not read Spaces through SkyLight"; return t }
        t.beforeAll = before
        if let owned = ownedFullScreenSpace(windowID: target.windowID, pid: target.pid, in: before) {
            t.error = "the window already owns full-screen Space \(owned.space.id)"
            return t
        }

        // Which Desktop is the window on, and which display is that?
        let windowSpaces = SpaceReader.spaces(forWindows: [target.windowID])[target.windowID] ?? []
        let home = homeSpace(ofWindowSpaces: windowSpaces, in: before)
        let fallback = before.first { $0.currentSpaceID == SpaceReader.activeSpaceID() } ?? before.first
        let displayID = home?.display.displayIdentifier ?? fallback?.displayIdentifier
        t.originSpaceID = home?.space.id
        t.displayIdentifier = displayID
        t.currentBefore = home?.display.currentSpaceID ?? fallback?.currentSpaceID

        if focus ?? (method != .ax) {
            t.focusNote = focusWindow(target, displayID: displayID, wantSpace: t.originSpaceID)
        }
        t.currentAtTrigger = currentSpace(ofDisplay: displayID)

        // Trigger, then poll.
        let knownIDs = Set(before.flatMap { $0.spaces.map(\.id) })
        let started = now()
        let trigger = fire(target, method: method, entering: true)
        t.triggerCallSeconds = now() - started
        t.triggered = trigger.ok
        t.triggerDetail = trigger.detail
        guard trigger.ok else { t.error = "trigger failed: \(trigger.detail)"; return t }

        var hit: (display: DisplaySpaces, space: SpaceInfo, matchedBy: String)?
        var latest = before
        let shown = waitUntil(timeout: timeout, interval: pollInterval) {
            guard let reading = try? SpaceReader.displays() else { return false }
            latest = reading
            if t.appearedSeconds == nil,
               reading.contains(where: { $0.spaces.contains { $0.kind == .fullscreen && !knownIDs.contains($0.id) } }) {
                t.appearedSeconds = now() - started
            }
            if let found = ownedFullScreenSpace(windowID: target.windowID, pid: target.pid, in: reading, excluding: knownIDs) {
                hit = found
                t.seconds = now() - started
                return true
            }
            return false
        }
        t.afterAll = latest
        t.axFullScreenAfter = AXWindows.isFullScreen(target.element)
        guard shown != nil, let found = hit else {
            t.error = t.appearedSeconds != nil
                ? "a new full-screen Space appeared but never became linked to this window within \(seconds(timeout))"
                : "no new full-screen Space appeared within \(seconds(timeout))"
            return t
        }
        t.succeeded = true
        t.fullScreenSpaceID = found.space.id
        t.matchedBy = found.matchedBy
        t.displayIdentifier = found.display.displayIdentifier
        t.fillPlacement(settled: false)
        absorbRaw(into: &t, display: found.display)

        // Let animations and any reordering finish, then read again.
        waitUntil(timeout: settle, interval: pollInterval) { false }
        if let settled = try? SpaceReader.displays() {
            t.settledAll = settled
            t.currentAfter = settled.first { $0.displayIdentifier == t.displayIdentifier }?.currentSpaceID
            t.fillPlacement(settled: true)
            if let display = settled.first(where: { $0.displayIdentifier == t.displayIdentifier }) {
                absorbRaw(into: &t, display: display)
            }
        }
        return t
    }

    /// Triggers exit from full screen for `target` and waits until its full-screen Space is gone, then notes
    /// which Desktop the window is on. Arguments as in `enter`.
    public static func exit(_ target: FullScreenTarget, method: FullScreenMethod, focus: Bool? = nil,
                            timeout: TimeInterval = defaultTimeout, settle: TimeInterval = defaultSettle) -> FullScreenTransition {
        var t = FullScreenTransition(direction: .exit, method: method, target: target)
        guard AXPermission.isTrusted() else { t.error = "Accessibility is not trusted for this process"; return t }
        guard let before = try? SpaceReader.displays() else { t.error = "could not read Spaces through SkyLight"; return t }
        t.beforeAll = before
        guard let owned = ownedFullScreenSpace(windowID: target.windowID, pid: target.pid, in: before) else {
            t.error = "the window does not own a full-screen Space"
            return t
        }
        let spaceID = owned.space.id
        t.fullScreenSpaceID = spaceID
        t.matchedBy = owned.matchedBy
        t.displayIdentifier = owned.display.displayIdentifier
        t.currentBefore = owned.display.currentSpaceID
        absorbRaw(into: &t, display: owned.display)

        if focus ?? (method != .ax) {
            t.focusNote = focusWindow(target, displayID: t.displayIdentifier, wantSpace: spaceID)
        }
        t.currentAtTrigger = currentSpace(ofDisplay: t.displayIdentifier)

        let started = now()
        let trigger = fire(target, method: method, entering: false)
        t.triggerCallSeconds = now() - started
        t.triggered = trigger.ok
        t.triggerDetail = trigger.detail
        guard trigger.ok else { t.error = "trigger failed: \(trigger.detail)"; return t }

        var latest = before
        let gone = waitUntil(timeout: timeout, interval: pollInterval) {
            guard let reading = try? SpaceReader.displays() else { return false }
            latest = reading
            if reading.contains(where: { $0.spaces.contains { $0.id == spaceID } }) { return false }
            t.seconds = now() - started
            return true
        }
        t.afterAll = latest
        guard gone != nil else {
            t.error = "the full-screen Space \(spaceID) still existed after \(seconds(timeout))"
            t.axFullScreenAfter = AXWindows.isFullScreen(target.element)
            return t
        }
        t.succeeded = true

        // Which Desktop is the window on now?
        let remaining = max(0.5, timeout - (now() - started))
        waitUntil(timeout: remaining, interval: pollInterval) {
            guard let reading = try? SpaceReader.displays() else { return false }
            let ids = SpaceReader.spaces(forWindows: [target.windowID])[target.windowID] ?? []
            guard let home = homeSpace(ofWindowSpaces: ids, in: reading), home.space.kind == .desktop else { return false }
            t.returnedSpaceID = home.space.id
            t.returnedSeconds = now() - started
            t.afterAll = reading
            return true
        }

        waitUntil(timeout: settle, interval: pollInterval) { false }
        if let settled = try? SpaceReader.displays() {
            t.settledAll = settled
            t.currentAfter = settled.first { $0.displayIdentifier == t.displayIdentifier }?.currentSpaceID
            let ids = SpaceReader.spaces(forWindows: [target.windowID])[target.windowID] ?? []
            t.returnedSettledSpaceID = homeSpace(ofWindowSpaces: ids, in: settled)
                .flatMap { $0.space.kind == .desktop ? $0.space.id : nil }
        }
        t.axFullScreenAfter = AXWindows.isFullScreen(target.element)
        return t
    }

    // MARK: - Triggers

    private static let fullScreenAttribute = "AXFullScreen"

    private static func fire(_ target: FullScreenTarget, method: FullScreenMethod, entering: Bool)
        -> (ok: Bool, detail: String) {
        switch method {
        case .ax:
            let value: CFBoolean = entering ? kCFBooleanTrue : kCFBooleanFalse
            let error = AXUIElementSetAttributeValue(target.element, fullScreenAttribute as CFString, value)
            return (error == .success, "AXFullScreen=\(entering) -> \(AX.errorName(error))")
        case .menu:
            // Menu titles are often stale until the menu is opened (a window that is already full screen can still
            // show "Enter Full Screen"), so fall back to any full-screen item, which is a toggle in practice.
            var notes: [String] = []
            var found = findFullScreenMenuItem(pid: target.pid, entering: entering)
            if found == nil, let any = findFullScreenMenuItem(pid: target.pid, entering: nil) {
                found = any
                notes.append("title \"\(any.title)\" does not say \(entering ? "enter" : "exit"); pressed it as a toggle")
            }
            guard let item = found else {
                return (false, "no full-screen item found in the app's menu bar")
            }
            // Pressed even when reported disabled (apps in the background often report that); the record shows the result.
            if !item.enabled { notes.append("item reported disabled") }
            let error = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
            let extra = notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"
            return (error == .success, "AXPress \"\(item.path)\" -> \(AX.errorName(error))\(extra)")
        case .keys:
            let source = CGEventSource(stateID: .privateState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeF, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeF, keyDown: false) else {
                return (false, "could not create the key events")
            }
            down.flags = [.maskControl, .maskCommand]
            up.flags = [.maskControl, .maskCommand]
            down.postToPid(target.pid)
            Thread.sleep(forTimeInterval: 0.03)
            up.postToPid(target.pid)
            return (true, "posted Ctrl+Cmd+F (key code \(keyCodeF)) to pid \(target.pid)")
        }
    }

    /// Makes the app frontmost and raises the window so menu / key triggers act on it. This can switch Space
    /// (macOS follows the activated window); waits briefly for `wantSpace` to become current.
    private static func focusWindow(_ target: FullScreenTarget, displayID: String?, wantSpace: UInt64?) -> String {
        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(appElement, 2.0)
        let front = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = target.app.activate()
        let raise = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
        let main = AXUIElementSetAttributeValue(target.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        var note = "focus: frontmost \(AX.errorName(front)), raise \(AX.errorName(raise)), main \(AX.errorName(main))"
        if let wantSpace, let displayID {
            if let took = waitUntil(timeout: 1.5, interval: pollInterval, { currentSpace(ofDisplay: displayID) == wantSpace }) {
                note += "; Space \(wantSpace) is current (after \(seconds(took)))"
            } else {
                note += "; Space \(wantSpace) did NOT become current within 1.5 s"
            }
        }
        waitUntil(timeout: 0.3, interval: pollInterval) { false }
        return note
    }

    // MARK: - Small helpers

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func seconds(_ value: TimeInterval) -> String { String(format: "%.2f s", value) }

    private static func currentSpace(ofDisplay identifier: String?) -> UInt64? {
        guard let identifier, let displays = try? SpaceReader.displays() else { return nil }
        return displays.first { $0.displayIdentifier == identifier }?.currentSpaceID
    }

    /// Reads `fromSpace` and key names for the transition's full-screen Space and resolves the Desktop.
    private static func absorbRaw(into t: inout FullScreenTransition, display: DisplaySpaces) {
        guard let id = t.fullScreenSpaceID, let info = rawFullScreenInfo()[id] else { return }
        t.rawKeys = info.keys
        if let from = info.fromSpace {
            t.fromSpaceUUID = from
            t.fromSpaceID = resolveFromSpace(from, in: display)?.id
        }
    }

    // MARK: - Raw SkyLight read for fromSpace

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    /// `fromSpace` and key names of every full-screen Space, read fresh from SkyLight (empty when unavailable).
    public static func rawFullScreenInfo() -> [UInt64: RawFullScreenInfo] {
        guard let connection = PrivateSymbols.lookup("SLSMainConnectionID", as: MainConnectionID.self),
              let copy = PrivateSymbols.lookup("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self),
              let array = copy(connection())?.takeRetainedValue() else { return [:] }
        return parseRawFullScreen((array as? [[String: Any]]) ?? [])
    }
}

extension FullScreenTransition {
    /// Fills the placement fields from `beforeAll` and the first (or settled) reading.
    fileprivate mutating func fillPlacement(settled: Bool) {
        guard let spaceID = fullScreenSpaceID else { return }
        let readings = settled ? settledAll : afterAll
        guard let after = readings.first(where: { $0.spaces.contains { $0.id == spaceID } }),
              let before = beforeAll.first(where: { $0.displayIdentifier == after.displayIdentifier }) else { return }
        let matches = FullScreenProbe.placementMatches(
            before: before, after: after, originSpaceID: originSpaceID,
            currentSpaceID: currentAtTrigger ?? before.currentSpaceID, newSpaceID: spaceID)
        if settled {
            placementSettled = matches[0]
        } else {
            placementMatches = matches
            placement = matches[0]
        }
    }
}

// MARK: - Accessibility helpers

private enum AX {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = value(element, attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        (value(element, attribute) as? [AXUIElement]) ?? []
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    static func errorName(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "AXError(\(error.rawValue))"
        }
    }
}
