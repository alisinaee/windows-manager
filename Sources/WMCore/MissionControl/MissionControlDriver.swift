import AppKit
import ApplicationServices
import Foundation

// Adds and removes Desktops by driving Mission Control through the Accessibility API of the Dock.
//
// There is no public API, and no SIP-on private API, for this. The approach and the Accessibility
// identifiers come from Hammerspoon's hs.spaces module (MIT licence,
// https://github.com/Hammerspoon/hammerspoon/tree/master/extensions/spaces, spaces.lua:
// addSpaceToScreen, removeSpace, openMissionControl, closeMissionControl). Credit to the Hammerspoon
// authors. No Hammerspoon code is copied; this file is our own implementation of the same idea:
//
//   Dock (com.apple.dock)
//     "mc"                      the Mission Control group, present only while Mission Control is open
//       "mc.display"            one per display, attribute AXDisplayID = CGDirectDisplayID
//         "mc.spaces"           the Spaces bar of that display
//           "mc.spaces.list"    one child per Space, in Mission Control order (full-screen Spaces too);
//                               each child supports the custom action "AXRemoveDesktop"
//           "mc.spaces.add"     the "+" button, pressed with AXPress
//
// Every state-changing call opens Mission Control, does its one action, verifies the result with
// `SpaceReader`, and always closes Mission Control again, even when something fails.

// MARK: - Errors

public enum MissionControlError: Error, LocalizedError, Equatable {
    case accessibilityNotTrusted
    case dockNotRunning
    case couldNotOpen(String)
    /// The "mc" group never showed up in the Dock's Accessibility children.
    case treeTimeout(TimeInterval)
    case missionControlNotOpen
    /// Mission Control is still on screen after every close attempt.
    case couldNotClose
    case displayNotFound(String)
    /// A group or button inside the Mission Control tree is missing; the text says which and what was there.
    case controlNotFound(String)
    /// The Spaces bar does not have one button per Space, so the button for a Space cannot be told apart.
    case listMismatch(expected: Int, found: Int, children: String)
    case actionFailed(action: String, code: Int32)
    case spaceNotFound(UInt64)
    case refused(DesktopRemovalRefusal)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility permission is missing for this terminal (System Settings > Privacy & Security > Accessibility)"
        case .dockNotRunning:
            return "The Dock is not running"
        case .couldNotOpen(let detail):
            return "Could not open Mission Control: \(detail)"
        case .treeTimeout(let seconds):
            return String(format: "Mission Control did not show up in the Dock's Accessibility tree within %.0f s", seconds)
        case .missionControlNotOpen:
            return "Mission Control is not open (the Dock has no \"mc\" group)"
        case .couldNotClose:
            return "Mission Control is still open after trying Escape and the launcher; close it by hand"
        case .displayNotFound(let detail):
            return detail
        case .controlNotFound(let detail):
            return "Mission Control control not found: \(detail)"
        case .listMismatch(let expected, let found, let children):
            return "The Spaces bar has \(found) button(s) but the display has \(expected) Space(s); "
                + "refusing to guess which one to press. Buttons: \(children)"
        case .actionFailed(let action, let code):
            return "\(action) failed with Accessibility error \(code)"
        case .spaceNotFound(let id):
            return "No Space with id \(id)"
        case .refused(let refusal):
            return "Refused: \(refusal)"
        case .verificationFailed(let detail):
            return "Verification failed: \(detail)"
        }
    }
}

// MARK: - Pure logic (no system calls)

/// Why a Desktop must not be removed.
public enum DesktopRemovalRefusal: Equatable, CustomStringConvertible {
    /// A full-screen (or other) Space. Close its window instead of removing it.
    case notADesktop(SpaceKind)
    /// Desktop 1 is never removed.
    case firstDesktop
    /// The Space that is visible on its display right now.
    case currentSpace
    /// Windows that live only on this Desktop (they would be moved to a neighbour Desktop).
    case hasWindows(Int)

    public var description: String {
        switch self {
        case .notADesktop(let kind):
            switch kind {
            case .fullscreen: return "this is a full-screen Space, not a Desktop (close its window to remove it)"
            default: return "this Space is not a normal Desktop"
            }
        case .firstDesktop:
            return "Desktop 1 is never removed"
        case .currentSpace:
            return "this is the current Space of its display; switch to another Desktop first"
        case .hasWindows(let count):
            return "\(count) window\(count == 1 ? "" : "s") still on this Desktop (use --force to remove it anyway)"
        }
    }

    /// True when `force` is allowed to override this refusal.
    public var canForce: Bool {
        if case .hasWindows = self { return true }
        return false
    }
}

public enum DesktopRemovalPolicy {
    /// The refusal rules for removing `space`, or nil when removing it is allowed.
    /// Order: not a Desktop, Desktop 1, current Space, windows. Only the windows rule yields to `force`.
    public static func refusal(for space: SpaceInfo, in display: DisplaySpaces,
                               blockingWindowCount: Int, force: Bool) -> DesktopRemovalRefusal? {
        guard space.kind == .desktop else { return .notADesktop(space.kind) }
        if display.desktopNumber(of: space) == 1 { return .firstDesktop }
        if space.isCurrent || display.currentSpaceID == space.id { return .currentSpace }
        if blockingWindowCount > 0 && !force { return .hasWindows(blockingWindowCount) }
        return nil
    }

    /// Windows that would be stranded by removing a Desktop: user-looking windows whose only Space is this
    /// one. Windows on several Spaces ("all Desktops") stay visible elsewhere, so they do not count.
    public static func blockingWindows(onSpace spaceID: UInt64, in windows: [CatalogWindow]) -> [CatalogWindow] {
        windows.filter { $0.looksLikeUserWindow && $0.spaceIDs == [spaceID] }
    }
}

/// What changed between two readings of one display's Spaces.
public struct SpacesDiff: Equatable {
    public var added: [UInt64]
    public var removed: [UInt64]

    public static func between(_ before: [SpaceInfo], _ after: [SpaceInfo]) -> SpacesDiff {
        let old = Set(before.map(\.id))
        let new = Set(after.map(\.id))
        return SpacesDiff(added: after.map(\.id).filter { !old.contains($0) },
                          removed: before.map(\.id).filter { !new.contains($0) })
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

/// What the matcher knows about one display: its CGDirectDisplayID and frame, either may be missing.
public struct DisplayGeometry: Equatable {
    public var displayID: UInt32?
    public var frame: CGRect?

    public init(displayID: UInt32? = nil, frame: CGRect? = nil) {
        self.displayID = displayID
        self.frame = frame
    }
}

public enum MissionControlDisplayMatcher {
    /// Picks the Mission Control display group (`groups`, in Accessibility order) that belongs to the
    /// display `target`. Rules, strongest first, each used only when it names exactly one group:
    /// 1. same CGDirectDisplayID, 2. same frame (within `tolerance` points), 3. same position in the list
    /// when both lists have the same length. Returns nil when nothing fits.
    public static func match(target: DisplayGeometry, position: Int, targetCount: Int,
                             groups: [DisplayGeometry], tolerance: CGFloat = 2) -> Int? {
        if let id = target.displayID {
            let hits = groups.indices.filter { groups[$0].displayID == id }
            if hits.count == 1 { return hits[0] }
        }
        if let frame = target.frame {
            let hits = groups.indices.filter { index in
                guard let other = groups[index].frame else { return false }
                return abs(other.minX - frame.minX) <= tolerance && abs(other.minY - frame.minY) <= tolerance
                    && abs(other.width - frame.width) <= tolerance && abs(other.height - frame.height) <= tolerance
            }
            if hits.count == 1 { return hits[0] }
        }
        if groups.count == targetCount, groups.indices.contains(position) { return position }
        return nil
    }

    /// Which children of "mc.spaces.list" are Space buttons. `roles` and `identifiers` are the children's
    /// AXRole and AXIdentifier in order. The add button is dropped; if the count still differs from
    /// `expected`, only AXButton children are kept. Returns child indices, or nil when no reading fits.
    public static func spaceButtonIndices(roles: [String?], identifiers: [String?], expected: Int) -> [Int]? {
        let all = roles.indices.filter { identifiers[$0] != "mc.spaces.add" }
        if all.count == expected { return all }
        let buttons = all.filter { roles[$0] == "AXButton" }
        if buttons.count == expected { return buttons }
        return nil
    }
}

/// One element of the Dock's Accessibility tree, for `dumpTree`.
public struct AXTreeNode: Codable, Equatable {
    public var role: String
    public var subrole: String?
    public var identifier: String?
    public var title: String?
    public var details: String?
    public var actions: [String]
    public var frame: CGRect?
    public var displayID: UInt32?
    public var children: [AXTreeNode]

    public init(role: String, subrole: String? = nil, identifier: String? = nil, title: String? = nil,
                details: String? = nil, actions: [String] = [], frame: CGRect? = nil, displayID: UInt32? = nil,
                children: [AXTreeNode] = []) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.details = details
        self.actions = actions
        self.frame = frame
        self.displayID = displayID
        self.children = children
    }

    /// One line per node, two spaces of indent per level.
    public static func render(_ nodes: [AXTreeNode], indent: Int = 0) -> String {
        var out = ""
        for node in nodes {
            var line = String(repeating: "  ", count: indent) + node.role
            if let subrole = node.subrole, !subrole.isEmpty { line += "/\(subrole)" }
            if let id = node.identifier, !id.isEmpty { line += " id=\"\(id)\"" }
            if let title = node.title, !title.isEmpty { line += " title=\"\(title)\"" }
            if let details = node.details, !details.isEmpty { line += " desc=\"\(details)\"" }
            if let displayID = node.displayID { line += " displayID=\(displayID)" }
            if let f = node.frame {
                line += " frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
            }
            if !node.actions.isEmpty { line += " actions=[\(node.actions.joined(separator: ", "))]" }
            out += line + "\n" + render(node.children, indent: indent + 1)
        }
        return out
    }
}

/// The outcome of a verified add or remove.
public struct DesktopChange {
    public var displayIdentifier: String
    public var before: DisplaySpaces
    public var after: DisplaySpaces
    public var diff: SpacesDiff

    public var desktopsBefore: Int { before.spaces.filter { $0.kind == .desktop }.count }
    public var desktopsAfter: Int { after.spaces.filter { $0.kind == .desktop }.count }
}

// MARK: - Accessibility helpers

private enum MCAX {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func identifier(_ element: AXUIElement) -> String? { string(element, "AXIdentifier") }
    static func role(_ element: AXUIElement) -> String? { string(element, "AXRole") }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, "AXChildren") as? [AXUIElement]) ?? []
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func displayID(_ element: AXUIElement) -> UInt32? {
        (value(element, "AXDisplayID") as? NSNumber)?.uint32Value
    }

    /// Breadth-first: the first element below `root` (up to `maxDepth` levels) with this identifier.
    static func firstDescendant(of root: AXUIElement, identifier: String, maxDepth: Int) -> AXUIElement? {
        var level = [root]
        for _ in 0..<maxDepth {
            var next: [AXUIElement] = []
            for element in level {
                for child in children(element) {
                    if MCAX.identifier(child) == identifier { return child }
                    next.append(child)
                }
            }
            if next.isEmpty { return nil }
            level = next
        }
        return nil
    }

    /// Breadth-first: every element below `root` (up to `maxDepth` levels) with this identifier.
    static func descendants(of root: AXUIElement, identifier: String, maxDepth: Int) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var level = [root]
        for _ in 0..<maxDepth {
            var next: [AXUIElement] = []
            for element in level {
                for child in children(element) {
                    if MCAX.identifier(child) == identifier { found.append(child) }
                    next.append(child)
                }
            }
            if next.isEmpty { break }
            level = next
        }
        return found
    }

    /// "AXButton id=… desc="…" actions=[…]" for log lines and error texts.
    static func summary(_ element: AXUIElement) -> String {
        var text = role(element) ?? "?"
        if let id = identifier(element), !id.isEmpty { text += " id=\(id)" }
        if let desc = string(element, "AXDescription"), !desc.isEmpty { text += " desc=\"\(desc)\"" }
        let names = actions(element)
        if !names.isEmpty { text += " actions=[\(names.joined(separator: ","))]" }
        return text
    }
}

// MARK: - Driver

/// Opens Mission Control, finds the controls of one display and presses them. One instance per run:
/// it collects `timings` (open MC, find button, press, verify, close) and `observations` for the lab result.
public final class MissionControlDriver {
    public struct Timing: Equatable {
        public var name: String
        public var seconds: TimeInterval
    }

    public static let dockBundleID = "com.apple.dock"
    public static let launcherBundleID = "com.apple.exposelauncher"
    public static let launcherPath = "/System/Applications/Mission Control.app"
    /// How long the Dock gets to show its "mc" group after Mission Control is launched.
    public static let treeTimeout: TimeInterval = 3
    /// How long SpaceReader gets to show the change after the button was pressed.
    public static let verifyTimeout: TimeInterval = 3

    public private(set) var timings: [Timing] = []
    public private(set) var observations: [(key: String, value: String)] = []
    /// Called with short progress lines (the command stores them as lab steps).
    public var log: ((String) -> Void)?

    public init() {}

    // MARK: Bookkeeping

    private func reset() {
        timings = []
        observations = []
    }

    private func observe(_ key: String, _ value: String) {
        if let index = observations.firstIndex(where: { $0.key == key }) {
            observations[index].value = value
        } else {
            observations.append((key, value))
        }
    }

    @discardableResult
    private func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let seconds = ProcessInfo.processInfo.systemUptime - start
            timings.append(Timing(name: name, seconds: seconds))
            log?(String(format: "%@ took %.3f s", name, seconds))
        }
        return try body()
    }

    private func pause(_ seconds: TimeInterval) {
        _ = waitUntil(timeout: seconds) { false }
    }

    // MARK: Dock and Mission Control

    private func dockElement() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first
        else { return nil }
        // Fresh every time: the Dock gets a new pid when it restarts.
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1.5)
        return element
    }

    /// The Dock's "mc" group, which exists only while Mission Control is open.
    private func missionControlGroup() -> AXUIElement? {
        guard let dock = dockElement() else { return nil }
        return MCAX.children(dock).first { MCAX.identifier($0) == "mc" }
    }

    public var isMissionControlOpen: Bool { missionControlGroup() != nil }

    /// Starts Mission Control.app (a launcher that toggles Mission Control).
    private func launchMissionControl() throws {
        var failures: [String] = []
        for arguments in [["-b", Self.launcherBundleID], [Self.launcherPath]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = arguments
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                failures.append("open \(arguments.joined(separator: " ")): \(error.localizedDescription)")
                continue
            }
            if process.terminationStatus == 0 { return }
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            failures.append("open \(arguments.joined(separator: " ")) exited \(process.terminationStatus) \(text)")
        }
        throw MissionControlError.couldNotOpen(failures.joined(separator: "; "))
    }

    private func pressEscape() {
        for keyDown in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: keyDown)?.post(tap: .cghidEventTap)
        }
    }

    /// Opens Mission Control and waits until the Dock's "mc" group exists (`treeTimeout`).
    /// Does nothing when it is already open.
    public func openMissionControl() throws {
        guard AXPermission.isTrusted() else { throw MissionControlError.accessibilityNotTrusted }
        guard dockElement() != nil else { throw MissionControlError.dockNotRunning }
        if isMissionControlOpen {
            observe("mission-control-was-open", "true")
            return
        }
        try launchMissionControl()
        guard waitUntil(timeout: Self.treeTimeout, interval: 0.05, { self.isMissionControlOpen }) != nil else {
            throw MissionControlError.treeTimeout(Self.treeTimeout)
        }
        pause(0.1)
    }

    /// Closes Mission Control: Escape first, then the launcher (it toggles), then Escape again.
    /// Never throws; returns false when Mission Control is still open afterwards.
    @discardableResult
    public func closeMissionControl() -> Bool {
        guard isMissionControlOpen else { return true }
        let attempts: [() -> Void] = [
            { self.pressEscape() },
            { try? self.launchMissionControl() },
            { self.pressEscape() },
        ]
        for (number, attempt) in attempts.enumerated() {
            attempt()
            if waitUntil(timeout: 1.5, interval: 0.05, { !self.isMissionControlOpen }) != nil {
                if number > 0 { observe("close-attempts", String(number + 1)) }
                pause(0.2) // let the close animation finish
                return true
            }
        }
        return false
    }

    /// Opens Mission Control, runs `body`, and always closes it again, also when `body` or the open fails.
    /// A failed close is reported only when `body` itself succeeded (it never hides `body`'s own error).
    public func withMissionControlOpen<T>(_ body: () throws -> T) throws -> T {
        let outcome = Result<T, Error> {
            try timed("open-mc") { try openMissionControl() }
            return try body()
        }
        let closed = timed("close-mc") { closeMissionControl() }
        if !closed { observe("close-failed", "true") }
        switch outcome {
        case .failure(let error): throw error
        case .success(let value):
            if !closed { throw MissionControlError.couldNotClose }
            return value
        }
    }

    // MARK: Tree dump

    /// The Dock's Accessibility tree: role, subrole, identifier, title, description, actions, frame.
    /// Mission Control must be open (use `withMissionControlOpen`). Stops after `maxNodes` elements.
    public func dumpTree(maxDepth: Int = 8, maxNodes: Int = 4000) throws -> [AXTreeNode] {
        guard AXPermission.isTrusted() else { throw MissionControlError.accessibilityNotTrusted }
        guard let dock = dockElement() else { throw MissionControlError.dockNotRunning }
        guard isMissionControlOpen else { throw MissionControlError.missionControlNotOpen }

        var budget = maxNodes
        func build(_ element: AXUIElement, depth: Int) -> AXTreeNode {
            budget -= 1
            var node = AXTreeNode(
                role: MCAX.role(element) ?? "?",
                subrole: MCAX.string(element, "AXSubrole"),
                identifier: MCAX.identifier(element),
                title: MCAX.string(element, "AXTitle"),
                details: MCAX.string(element, "AXDescription"),
                actions: MCAX.actions(element),
                frame: AXWindows.frame(of: element),
                displayID: MCAX.displayID(element)
            )
            if depth < maxDepth {
                for child in MCAX.children(element) {
                    if budget <= 0 { break }
                    node.children.append(build(child, depth: depth + 1))
                }
            }
            return node
        }
        var roots: [AXTreeNode] = []
        for child in MCAX.children(dock) {
            if budget <= 0 { break }
            roots.append(build(child, depth: 1))
        }
        return roots
    }

    // MARK: Locating controls

    private struct DisplayGroup {
        var element: AXUIElement
        var geometry: DisplayGeometry
    }

    private struct SpacesControls {
        var groupCount: Int
        var groupIndex: Int
        var geometry: DisplayGeometry
        var list: AXUIElement?
        var addButton: AXUIElement?
    }

    private enum Need { case addButton, list }

    private func displayGroups(in mc: AXUIElement) -> [DisplayGroup] {
        MCAX.descendants(of: mc, identifier: "mc.display", maxDepth: 3).map {
            DisplayGroup(element: $0, geometry: DisplayGeometry(displayID: MCAX.displayID($0),
                                                                 frame: AXWindows.frame(of: $0)))
        }
    }

    /// The SkyLight display identifier ("Main" or a UUID) as CGDirectDisplayID and frame.
    static func geometry(forDisplayIdentifier identifier: String) -> DisplayGeometry {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if count > 0 { CGGetActiveDisplayList(count, &ids, &count) }

        var match: CGDirectDisplayID?
        if identifier == "Main" {
            match = CGMainDisplayID()
        } else {
            for id in ids {
                guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                      let text = CFUUIDCreateString(nil, uuid) as String? else { continue }
                if text.caseInsensitiveCompare(identifier) == .orderedSame {
                    match = id
                    break
                }
            }
        }
        guard let match else { return DisplayGeometry() }
        return DisplayGeometry(displayID: match, frame: CGDisplayBounds(match))
    }

    private static func describe(_ geometry: DisplayGeometry) -> String {
        let id = geometry.displayID.map(String.init) ?? "?"
        guard let f = geometry.frame else { return "displayID \(id)" }
        return "displayID \(id) frame \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
    }

    /// Polls (up to `treeTimeout`) until the display's Spaces bar and the control we need are in the tree.
    private func locateControls(display: DisplaySpaces, position: Int, displayCount: Int,
                                need: Need) throws -> SpacesControls {
        let target = Self.geometry(forDisplayIdentifier: display.displayIdentifier)
        observe("display-geometry", Self.describe(target))

        var problem = "the \"mc\" group disappeared"
        var found: SpacesControls?
        let waited = waitUntil(timeout: Self.treeTimeout, interval: 0.1) {
            guard let mc = self.missionControlGroup() else { return false }
            let groups = self.displayGroups(in: mc)
            guard !groups.isEmpty else {
                problem = "no \"mc.display\" group inside \"mc\" yet"
                return false
            }
            guard let index = MissionControlDisplayMatcher.match(
                target: target, position: position, targetCount: displayCount, groups: groups.map(\.geometry)
            ) else {
                problem = "no \"mc.display\" group matches this display (\(Self.describe(target))); groups: "
                    + groups.map { Self.describe($0.geometry) }.joined(separator: " | ")
                return false
            }
            let group = groups[index].element
            let list = MCAX.firstDescendant(of: group, identifier: "mc.spaces.list", maxDepth: 6)
            let add = MCAX.firstDescendant(of: group, identifier: "mc.spaces.add", maxDepth: 6)
            switch need {
            case .addButton where add == nil:
                problem = "display group \(index + 1) has no \"mc.spaces.add\" button"
                return false
            case .list where list == nil:
                problem = "display group \(index + 1) has no \"mc.spaces.list\""
                return false
            default:
                break
            }
            found = SpacesControls(groupCount: groups.count, groupIndex: index, geometry: groups[index].geometry,
                                   list: list, addButton: add)
            return true
        }
        guard waited != nil, let controls = found else { throw MissionControlError.controlNotFound(problem) }

        observe("mc-display-groups", String(controls.groupCount))
        observe("mc-display-group-used", "\(controls.groupIndex + 1): \(Self.describe(controls.geometry))")
        return controls
    }

    // MARK: Reading Spaces

    private func currentDisplay(_ identifier: String) -> DisplaySpaces? {
        (try? SpaceReader.displays())?.first { $0.displayIdentifier == identifier }
    }

    /// Polls SpaceReader until `isExpected` accepts the display. Returns the last reading and whether it matched.
    private func waitForSpaces(display identifier: String, timeout: TimeInterval,
                               _ isExpected: (DisplaySpaces) -> Bool) -> (display: DisplaySpaces?, matched: Bool) {
        var last: DisplaySpaces?
        let waited = waitUntil(timeout: timeout, interval: 0.05) {
            guard let now = self.currentDisplay(identifier) else { return false }
            last = now
            return isExpected(now)
        }
        return (last, waited != nil)
    }

    private static func desktopCount(_ display: DisplaySpaces) -> Int {
        display.spaces.filter { $0.kind == .desktop }.count
    }

    // MARK: Add

    /// Adds one Desktop to the display at `displayIndex` (0-based, the order of `SpaceReader.displays()`).
    /// Verifies that exactly one new Desktop appeared and no other Space changed. Always closes Mission Control.
    @discardableResult
    public func addDesktop(displayIndex: Int) throws -> DesktopChange {
        reset()
        let displays = try SpaceReader.displays()
        guard displays.indices.contains(displayIndex) else {
            throw MissionControlError.displayNotFound(
                "Display \(displayIndex + 1) does not exist; SkyLight reports \(displays.count) display(s)")
        }
        let before = displays[displayIndex]
        let identifier = before.displayIdentifier
        observe("display-identifier", identifier)
        observe("desktops-before", String(Self.desktopCount(before)))

        func isExpected(_ now: DisplaySpaces) -> Bool {
            let diff = SpacesDiff.between(before.spaces, now.spaces)
            guard diff.removed.isEmpty, diff.added.count == 1,
                  let added = now.spaces.first(where: { $0.id == diff.added[0] }) else { return false }
            return added.kind == .desktop
        }

        var seenWhileOpen = false
        try withMissionControlOpen {
            let controls = try timed("find-button") {
                try locateControls(display: before, position: displayIndex, displayCount: displays.count,
                                   need: .addButton)
            }
            guard let button = controls.addButton else {
                throw MissionControlError.controlNotFound("\"mc.spaces.add\"")
            }
            observe("add-button", MCAX.summary(button))
            try timed("press") {
                let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
                guard error == .success else {
                    throw MissionControlError.actionFailed(action: "AXPress", code: error.rawValue)
                }
            }
            log?("pressed mc.spaces.add")
            seenWhileOpen = timed("verify") {
                waitForSpaces(display: identifier, timeout: Self.verifyTimeout, isExpected).matched
            }
        }
        observe("change-seen-while-mission-control-open", String(seenWhileOpen))

        let verdict = seenWhileOpen
            ? waitForSpaces(display: identifier, timeout: 0.5, isExpected)
            : timed("verify-after-close") { waitForSpaces(display: identifier, timeout: 2, isExpected) }
        guard verdict.matched, let after = verdict.display else {
            throw MissionControlError.verificationFailed(
                "expected exactly one new Desktop on the display; \(Self.differenceText(before: before, now: verdict.display))")
        }
        let diff = SpacesDiff.between(before.spaces, after.spaces)
        observe("desktops-after", String(Self.desktopCount(after)))
        observe("added-space-id", diff.added.map(String.init).joined(separator: ","))
        return DesktopChange(displayIdentifier: identifier, before: before, after: after, diff: diff)
    }

    // MARK: Remove

    /// Removes the Desktop with this Space id. The refusal rules (`DesktopRemovalPolicy`) apply first:
    /// not Desktop 1, not the current Space, not a full-screen Space, and no windows unless `force`.
    /// `windows` can be passed to avoid reading the window catalog twice. Verifies that exactly this Space
    /// disappeared. Always closes Mission Control.
    @discardableResult
    public func removeDesktop(spaceID: UInt64, force: Bool = false,
                              windows: [CatalogWindow]? = nil) throws -> DesktopChange {
        reset()
        let displays = try SpaceReader.displays()
        guard let displayIndex = displays.firstIndex(where: { $0.spaces.contains { $0.id == spaceID } }),
              let space = displays[displayIndex].spaces.first(where: { $0.id == spaceID }) else {
            throw MissionControlError.spaceNotFound(spaceID)
        }
        let before = displays[displayIndex]
        let identifier = before.displayIdentifier

        let blocking = DesktopRemovalPolicy.blockingWindows(onSpace: spaceID, in: windows ?? WindowCatalog.all())
        if let refusal = DesktopRemovalPolicy.refusal(for: space, in: before, blockingWindowCount: blocking.count,
                                                      force: force) {
            throw MissionControlError.refused(refusal)
        }
        observe("display-identifier", identifier)
        observe("space-index", String(space.index))
        observe("desktops-before", String(Self.desktopCount(before)))
        observe("windows-on-desktop", String(blocking.count))

        func isExpected(_ now: DisplaySpaces) -> Bool {
            let diff = SpacesDiff.between(before.spaces, now.spaces)
            return diff.added.isEmpty && diff.removed == [spaceID]
        }

        var seenWhileOpen = false
        try withMissionControlOpen {
            let controls = try timed("find-button") {
                try locateControls(display: before, position: displayIndex, displayCount: displays.count,
                                   need: .list)
            }
            guard let list = controls.list else { throw MissionControlError.controlNotFound("\"mc.spaces.list\"") }

            let children = MCAX.children(list)
            let roles = children.map { MCAX.role($0) }
            let identifiers = children.map { MCAX.identifier($0) }
            observe("spaces-list-children", String(children.count))
            guard let indices = MissionControlDisplayMatcher.spaceButtonIndices(
                roles: roles, identifiers: identifiers, expected: before.spaces.count
            ) else {
                throw MissionControlError.listMismatch(
                    expected: before.spaces.count, found: children.count,
                    children: children.prefix(12).map { MCAX.summary($0) }.joined(separator: " | "))
            }
            let button = children[indices[space.index]]
            observe("remove-button", MCAX.summary(button))

            let names = MCAX.actions(button)
            // The action is "AXRemoveDesktop"; accept a variant that contains the word, else try the plain name.
            let action = names.first { $0 == "AXRemoveDesktop" } ?? names.first { $0.contains("RemoveDesktop") }
                ?? "AXRemoveDesktop"
            if !names.contains(action) { observe("remove-action-listed", "false") }
            try timed("press") {
                let error = AXUIElementPerformAction(button, action as CFString)
                guard error == .success else {
                    throw MissionControlError.actionFailed(action: action, code: error.rawValue)
                }
            }
            log?("performed \(action) on Space button \(space.index + 1)")
            seenWhileOpen = timed("verify") {
                waitForSpaces(display: identifier, timeout: Self.verifyTimeout, isExpected).matched
            }
        }
        observe("change-seen-while-mission-control-open", String(seenWhileOpen))

        let verdict = seenWhileOpen
            ? waitForSpaces(display: identifier, timeout: 0.5, isExpected)
            : timed("verify-after-close") { waitForSpaces(display: identifier, timeout: 2, isExpected) }
        guard verdict.matched, let after = verdict.display else {
            throw MissionControlError.verificationFailed(
                "expected only Space \(spaceID) to disappear; \(Self.differenceText(before: before, now: verdict.display))")
        }
        let diff = SpacesDiff.between(before.spaces, after.spaces)
        observe("desktops-after", String(Self.desktopCount(after)))
        observe("removed-space-id", String(spaceID))
        return DesktopChange(displayIdentifier: identifier, before: before, after: after, diff: diff)
    }

    private static func differenceText(before: DisplaySpaces, now: DisplaySpaces?) -> String {
        guard let now else { return "the display could not be read afterwards" }
        let diff = SpacesDiff.between(before.spaces, now.spaces)
        return "Desktops \(desktopCount(before)) -> \(desktopCount(now)), added \(diff.added), removed \(diff.removed)"
    }
}
