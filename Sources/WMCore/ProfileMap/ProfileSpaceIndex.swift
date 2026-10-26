import CoreGraphics
import Foundation

// Groups a saved profile by Space (PM2). The map viewer and the Builder read this index instead of
// walking `Profile.spaces` and `Profile.windows` themselves, so the rules live in one place:
// - each display lists its Spaces in Mission Control order: Desktops and full-screen Spaces;
// - a Split View Space has two owner windows and is drawn as two halves;
// - "On all Desktops" windows are listed on every Desktop of their display;
// - minimized windows, and windows whose placement is unknown or whose full-screen Space has no owner,
//   go to the tray and are on no Space.
// Pure value logic: no AppKit, no SwiftUI.

public struct ProfileSpaceIndex: Equatable, Sendable {
    /// One Space of one display, in Mission Control order.
    public struct Space: Hashable, Sendable, Identifiable {
        /// `"<displayUUID>#<position>"`, the same id as `SpaceSnapshot.id`.
        public var id: String
        /// `DisplayIdentity.uuid` of the display this Space belongs to.
        public var displayUUID: String
        /// 0-based position in Mission Control order on that display (full-screen Spaces count).
        public var position: Int
        /// `.desktop`, `.fullScreen` or `.other`.
        public var kind: SavedSpaceKind
        /// 1-based "Desktop N" number, only for Desktops.
        public var desktopNumber: Int?
        /// Owner windows of a full-screen Space in profile order: one, or two for Split View.
        /// Split View halves are drawn left to right in the order the layout sorts them, not here.
        public var fullScreenWindowIDs: [UUID]
        /// Windows drawn in this Space, back to front (highest `zIndex` first). For a Desktop this holds the
        /// Desktop's own windows plus the "On all Desktops" windows of the display. For a full-screen Space it
        /// holds its owner windows.
        public var windowIDs: [UUID]

        /// A full-screen Space with two owner windows.
        public var isSplitView: Bool { kind == .fullScreen && fullScreenWindowIDs.count > 1 }

        /// True when no window is drawn in this Space.
        public var isEmpty: Bool { windowIDs.isEmpty }

        public init(id: String, displayUUID: String, position: Int, kind: SavedSpaceKind,
                    desktopNumber: Int?, fullScreenWindowIDs: [UUID], windowIDs: [UUID]) {
            self.id = id
            self.displayUUID = displayUUID
            self.position = position
            self.kind = kind
            self.desktopNumber = desktopNumber
            self.fullScreenWindowIDs = fullScreenWindowIDs
            self.windowIDs = windowIDs
        }
    }

    /// Why a window is in the tray instead of on a Space.
    public enum TrayReason: String, Hashable, Sendable {
        /// The window was minimized at capture; it has no place on a Space.
        case minimized
        /// The window is on all Desktops. It is also drawn on every Desktop of its display.
        case onAllDesktops
        /// The window has no usable placement (unknown, or a full-screen window without an owning Space).
        case unplaced
    }

    public struct TrayEntry: Hashable, Sendable {
        public var windowID: UUID
        public var displayUUID: String
        public var reason: TrayReason

        public init(windowID: UUID, displayUUID: String, reason: TrayReason) {
            self.windowID = windowID
            self.displayUUID = displayUUID
            self.reason = reason
        }
    }

    /// Every Space, grouped by display in the order the displays appear (profile displays first), then by position.
    public private(set) var spaces: [Space]
    /// Windows that are not on a Space, in profile order.
    public private(set) var tray: [TrayEntry]

    public init(profile: Profile) {
        var displayOrder: [String] = []
        func note(_ uuid: String) {
            if !displayOrder.contains(uuid) { displayOrder.append(uuid) }
        }
        for display in profile.displays { note(display.uuid) }
        for space in profile.spaces { note(space.displayUUID) }
        for window in profile.windows { note(window.displayUUID) }

        var result: [Space] = []
        var trayEntries: [TrayEntry] = []

        for uuid in displayOrder {
            let displayWindows = profile.windows.filter { $0.displayUUID == uuid }
            let spaceSnapshots = profile.spaces(onDisplay: uuid)

            // Desktop windows (not minimized, not full screen) and full-screen windows per Desktop number.
            var desktopNumbers = Set(spaceSnapshots.compactMap { $0.kind == .desktop ? $0.desktopNumber : nil })
            for window in displayWindows where !window.isMinimized && !window.isFullScreen {
                if case .desktop(let number) = window.placement { desktopNumbers.insert(number) }
            }

            // Build the ordered Space list for this display.
            var drafts: [Space] = []
            if spaceSnapshots.isEmpty {
                // Old profiles without Space snapshots: Desktops by number, then full-screen Spaces by position.
                for number in desktopNumbers.sorted() {
                    drafts.append(Space(id: "\(uuid)#\(drafts.count)", displayUUID: uuid, position: drafts.count,
                                        kind: .desktop, desktopNumber: number, fullScreenWindowIDs: [], windowIDs: []))
                }
            } else {
                for snapshot in spaceSnapshots {
                    drafts.append(Space(id: snapshot.id, displayUUID: uuid, position: snapshot.position,
                                        kind: snapshot.kind, desktopNumber: snapshot.desktopNumber,
                                        fullScreenWindowIDs: snapshot.fullScreenWindowIDs, windowIDs: []))
                }
                // Desktops that windows refer to but no snapshot lists are appended in number order.
                let listed = Set(spaceSnapshots.compactMap { $0.kind == .desktop ? $0.desktopNumber : nil })
                for number in desktopNumbers.sorted() where !listed.contains(number) {
                    drafts.append(Space(id: "\(uuid)#\(drafts.count)", displayUUID: uuid, position: drafts.count,
                                        kind: .desktop, desktopNumber: number, fullScreenWindowIDs: [], windowIDs: []))
                }
            }

            // Fill windows. Back to front: highest zIndex first, profile order on ties.
            let backToFront = displayWindows.enumerated()
                .sorted { ($0.element.zIndex, $0.offset) > ($1.element.zIndex, $1.offset) }
                .map(\.element)

            let ownerSpaceIndex: [UUID: Int] = Dictionary(
                drafts.enumerated().flatMap { index, space in space.fullScreenWindowIDs.map { ($0, index) } },
                uniquingKeysWith: { first, _ in first })

            var placed = Set<UUID>()
            for window in backToFront {
                if window.isMinimized { continue }
                if window.placement == .allDesktops {
                    // Drawn on every Desktop of this display; listed in the tray as well.
                    trayEntries.append(TrayEntry(windowID: window.id, displayUUID: uuid, reason: .onAllDesktops))
                    for index in drafts.indices where drafts[index].kind == .desktop {
                        drafts[index].windowIDs.append(window.id)
                    }
                    continue
                }
                if let owner = ownerSpaceIndex[window.id], drafts[owner].kind == .fullScreen {
                    drafts[owner].windowIDs.append(window.id)
                    placed.insert(window.id)
                    continue
                }
                var isFullScreenWindow = window.isFullScreen
                if case .fullScreen = window.placement { isFullScreenWindow = true }
                if isFullScreenWindow {
                    // Full-screen window with no owning Space: tray.
                    continue
                }
                if case .desktop(let number) = window.placement,
                   let index = drafts.firstIndex(where: { $0.kind == .desktop && $0.desktopNumber == number }) {
                    drafts[index].windowIDs.append(window.id)
                    placed.insert(window.id)
                }
            }

            // Tray: minimized and unplaced windows of this display (all-Desktops ones were added above).
            for window in displayWindows {
                if window.isMinimized {
                    trayEntries.append(TrayEntry(windowID: window.id, displayUUID: uuid, reason: .minimized))
                } else if window.placement != .allDesktops && !placed.contains(window.id) {
                    trayEntries.append(TrayEntry(windowID: window.id, displayUUID: uuid, reason: .unplaced))
                }
            }

            result.append(contentsOf: drafts)
        }

        // Tray entries in profile order, not grouped by display.
        let order = Dictionary(profile.windows.enumerated().map { ($0.element.id, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        trayEntries.sort { (order[$0.windowID] ?? Int.max) < (order[$1.windowID] ?? Int.max) }

        self.spaces = result
        self.tray = trayEntries
    }

    /// Spaces of one display in Mission Control order.
    public func spaces(onDisplay displayUUID: String) -> [Space] {
        spaces.filter { $0.displayUUID == displayUUID }.sorted { $0.position < $1.position }
    }

    /// The Space with this id (`"<displayUUID>#<position>"`), if any.
    public func space(id: String) -> Space? {
        spaces.first { $0.id == id }
    }

    /// The Desktop with this number on that display, if any.
    public func desktop(number: Int, onDisplay displayUUID: String) -> Space? {
        spaces.first { $0.displayUUID == displayUUID && $0.kind == .desktop && $0.desktopNumber == number }
    }

    /// The Space a monitor tile shows when nothing is selected yet.
    /// Desktop 1 when it has windows. When Desktop 1 is empty, the Space with the most windows
    /// (first in Mission Control order on a tie). When no Space has windows, Desktop 1, else the first Space.
    /// Nil when the display has no Spaces.
    public func defaultSpaceID(displayUUID: String) -> String? {
        let displaySpaces = spaces(onDisplay: displayUUID)
        let desktop1 = displaySpaces.first { $0.kind == .desktop && $0.desktopNumber == 1 }
        if let desktop1, !desktop1.isEmpty { return desktop1.id }

        if let busiest = displaySpaces.max(by: { lhs, rhs in
            // Max by window count; on a tie the earlier position wins, so compare the later one as "smaller".
            if lhs.windowIDs.count != rhs.windowIDs.count { return lhs.windowIDs.count < rhs.windowIDs.count }
            return lhs.position > rhs.position
        }), !busiest.isEmpty {
            return busiest.id
        }
        return (desktop1 ?? displaySpaces.first)?.id
    }

    /// Tray entries of one display, in profile order.
    public func tray(onDisplay displayUUID: String) -> [TrayEntry] {
        tray.filter { $0.displayUUID == displayUUID }
    }
}
