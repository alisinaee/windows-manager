import Foundation

// "Start from the current workspace" lets people pick what to keep from a fresh capture (P6.47).
// `CaptureSelectionTree` groups the captured windows as monitor > Desktop / full-screen Space > window,
// `CaptureSelection` holds the ticked boxes, and `applying(to:)` builds the profile from the ticked items only.
// Pure value logic: no AppKit, no SwiftUI.

/// The captured profile as a tree of monitors, Spaces and windows. Every window sits in exactly one group:
/// its Space, or the monitor's "other windows" group (minimized, on all Desktops, or without a usable Space).
public struct CaptureSelectionTree: Equatable, Sendable {
    public struct Group: Equatable, Sendable, Identifiable {
        /// `SpaceSnapshot`-style id (`"<displayUUID>#<position>"`) for a Space, `"<displayUUID>#other"` for the other-windows group.
        public var id: String
        /// The Space this group stands for; nil for the other-windows group.
        public var spaceID: String?
        public var kind: SavedSpaceKind
        public var desktopNumber: Int?
        /// Windows in profile order.
        public var windowIDs: [UUID]

        public var isOtherWindows: Bool { spaceID == nil }
    }

    public struct Monitor: Equatable, Sendable, Identifiable {
        public var id: String { displayUUID }
        public var displayUUID: String
        /// Nil when the profile lists windows or Spaces for a display it does not describe.
        public var display: DisplayIdentity?
        public var groups: [Group]

        public var windowIDs: [UUID] { groups.flatMap(\.windowIDs) }
    }

    public var monitors: [Monitor]

    public var allWindowIDs: [UUID] { monitors.flatMap(\.windowIDs) }
    public var allSpaceIDs: [String] { monitors.flatMap { $0.groups.compactMap(\.spaceID) } }

    public init(profile: Profile) {
        let index = ProfileSpaceIndex(profile: profile)
        let order = Dictionary(profile.windows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var displayOrder: [String] = []
        for uuid in profile.displays.map(\.uuid) + index.spaces.map(\.displayUUID) + profile.windows.map(\.displayUUID)
        where !displayOrder.contains(uuid) {
            displayOrder.append(uuid)
        }
        let allDesktopsIDs = Set(profile.windows.filter { $0.placement == .allDesktops }.map(\.id))

        var result: [Monitor] = []
        for uuid in displayOrder {
            var groups: [Group] = []
            var placed = Set<UUID>()
            for space in index.spaces(onDisplay: uuid) {
                // "On all Desktops" windows are drawn on every Desktop; here they belong to the other-windows group only.
                let ids = space.windowIDs.filter { !allDesktopsIDs.contains($0) }
                    .sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
                placed.formUnion(ids)
                groups.append(Group(id: space.id, spaceID: space.id, kind: space.kind,
                                    desktopNumber: space.desktopNumber, windowIDs: ids))
            }
            let rest = profile.windows.filter { $0.displayUUID == uuid && !placed.contains($0.id) }.map(\.id)
            if !rest.isEmpty {
                groups.append(Group(id: "\(uuid)#other", spaceID: nil, kind: .other, desktopNumber: nil, windowIDs: rest))
            }
            result.append(Monitor(displayUUID: uuid, display: profile.displays.first { $0.uuid == uuid }, groups: groups))
        }
        monitors = result
    }
}

/// Three-state check box value of a group or monitor.
public enum CaptureCheckState: Equatable, Sendable {
    case on, off, mixed
}

/// What is ticked. Windows are ticked by id; a Space that holds no windows is ticked by its own id
/// (a Space with windows is ticked exactly when one of its windows is).
public struct CaptureSelection: Equatable, Sendable {
    public private(set) var windowIDs: Set<UUID>
    public private(set) var spaceIDs: Set<String>
    public let tree: CaptureSelectionTree

    /// Everything ticked, which is what a capture started with before there was a choice.
    public init(tree: CaptureSelectionTree) {
        self.tree = tree
        windowIDs = Set(tree.allWindowIDs)
        spaceIDs = Set(tree.allSpaceIDs)
    }

    public var totalWindows: Int { tree.allWindowIDs.count }
    public var selectedWindows: Int { windowIDs.count }
    /// "Create draft" needs something to create: a window, or at least an empty Space that is ticked.
    public var hasSelection: Bool { !windowIDs.isEmpty || !spaceIDs.isEmpty }

    public mutating func selectAll() {
        windowIDs = Set(tree.allWindowIDs)
        spaceIDs = Set(tree.allSpaceIDs)
    }

    public mutating func selectNone() {
        windowIDs = []
        spaceIDs = []
    }

    // MARK: States

    public func isSelected(window id: UUID) -> Bool { windowIDs.contains(id) }

    public func state(of group: CaptureSelectionTree.Group) -> CaptureCheckState {
        if group.windowIDs.isEmpty {
            guard let id = group.spaceID else { return .off }
            return spaceIDs.contains(id) ? .on : .off
        }
        return Self.state(ticked: group.windowIDs.filter(windowIDs.contains).count, of: group.windowIDs.count)
    }

    public func state(of monitor: CaptureSelectionTree.Monitor) -> CaptureCheckState {
        var ticked = 0, total = 0
        for group in monitor.groups {
            if group.windowIDs.isEmpty {
                total += 1
                if state(of: group) == .on { ticked += 1 }
            } else {
                total += group.windowIDs.count
                ticked += group.windowIDs.filter(windowIDs.contains).count
            }
        }
        return Self.state(ticked: ticked, of: total)
    }

    private static func state(ticked: Int, of total: Int) -> CaptureCheckState {
        if ticked == 0 { return .off }
        return ticked == total ? .on : .mixed
    }

    // MARK: Toggles

    public mutating func toggle(window id: UUID) {
        if windowIDs.contains(id) { windowIDs.remove(id) } else { windowIDs.insert(id) }
    }

    /// Ticks everything under the group unless it is fully ticked already, then it clears everything.
    public mutating func toggle(group: CaptureSelectionTree.Group) {
        set(group: group, on: state(of: group) != .on)
    }

    public mutating func toggle(monitor: CaptureSelectionTree.Monitor) {
        let on = state(of: monitor) != .on
        for group in monitor.groups { set(group: group, on: on) }
    }

    private mutating func set(group: CaptureSelectionTree.Group, on: Bool) {
        if on {
            windowIDs.formUnion(group.windowIDs)
            if let id = group.spaceID { spaceIDs.insert(id) }
        } else {
            windowIDs.subtract(group.windowIDs)
            if let id = group.spaceID { spaceIDs.remove(id) }
        }
    }

    // MARK: Result

    /// The profile with only the ticked windows. A Space is kept when one of its windows is kept, or when it had no
    /// windows and is ticked; a full-screen Space loses owners that were left out and goes with its last owner.
    /// A monitor is kept when a window or Space on it is kept. Positions are packed again; launch-plan entries of apps that
    /// no longer have a window are dropped.
    public func applying(to profile: Profile) -> Profile {
        var result = profile
        result.windows = profile.windows.filter { windowIDs.contains($0.id) }
        let kept = Set(result.windows.map(\.id))

        let originallyHeld = Set(tree.monitors.flatMap(\.groups).filter { !$0.windowIDs.isEmpty }.compactMap(\.spaceID))
        var spaces: [SpaceSnapshot] = []
        for var space in profile.spaces {
            let owners = space.fullScreenWindowIDs.filter(kept.contains)
            let holdsKept = tree.monitors.flatMap(\.groups).first { $0.spaceID == space.id }?.windowIDs.contains(where: kept.contains) ?? false
            if space.kind == .fullScreen {
                guard !owners.isEmpty else { continue }
                space.fullScreenWindowIDs = owners
            } else if originallyHeld.contains(space.id) {
                guard holdsKept else { continue }
            } else {
                guard spaceIDs.contains(space.id) || holdsKept else { continue }
            }
            spaces.append(space)
        }
        // Positions stay in Mission Control order but without gaps, per display.
        var next: [String: Int] = [:]
        let sorted = spaces.enumerated().sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }
        for (offset, space) in sorted {
            let position = next[space.displayUUID, default: 0]
            next[space.displayUUID] = position + 1
            spaces[offset].position = position
        }
        result.spaces = spaces

        let usedDisplays = Set(result.windows.map(\.displayUUID)).union(spaces.map(\.displayUUID))
        result.displays = profile.displays.filter { usedDisplays.contains($0.uuid) }

        if var plan = profile.launchPlan {
            let remaining = result.apps
            plan.items = plan.items.filter { item in
                item.withoutWindows || remaining.contains { Profile.isSameApp($0, item.app) }
            }
            result.launchPlan = plan
        }
        return result
    }
}
