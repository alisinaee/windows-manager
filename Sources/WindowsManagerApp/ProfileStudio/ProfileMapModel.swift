import AppKit
import CoreGraphics
import Foundation
import WMCore

/// Direction of an arrow key on the map.
enum MapDirection {
    case left, right, up, down
}

/// State of one map: the profile, its Space index, what is selected, the zoom and the computed layout.
/// The geometry itself comes from `ProfileMapLayout` (WMCore); this class only holds state and glue.
@MainActor
final class ProfileMapModel: ObservableObject {
    @Published private(set) var profile: Profile?
    @Published private(set) var index = ProfileSpaceIndex(profile: Profile.emptyForMap)
    /// Selected Space per display uuid. A display missing here shows its default Space.
    @Published private(set) var spaceSelection: [String: String] = [:]
    @Published private(set) var selectedWindowID: UUID?
    /// The monitor that keyboard Space navigation starts from.
    @Published private(set) var focusedDisplayUUID: String?
    @Published private(set) var zoom: Double = 1
    @Published private(set) var viewport: CGSize = CGSize(width: 800, height: 500)
    /// Optional live status ("Compare with now"). Nil hides every status badge.
    @Published var status: ProfileLiveStatus?
    @Published private(set) var layout: ProfileMapLayout = .empty(viewport: CGSize(width: 800, height: 500))

    /// `WindowTile.id` under the pointer (hover highlight only).
    @Published private(set) var hoveredTileID: String?

    private var pinchBase: Double?

    // MARK: Loading

    func load(_ profile: Profile?) {
        let changed = self.profile?.id != profile?.id
        self.profile = profile
        index = ProfileSpaceIndex(profile: profile ?? Profile.emptyForMap)
        if changed {
            spaceSelection = [:]
            selectedWindowID = nil
            focusedDisplayUUID = profile?.displays.first?.uuid
        }
        relayout()
    }

    // MARK: Layout

    func setViewport(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != viewport else { return }
        viewport = size
        relayout()
    }

    func setZoom(_ value: Double) {
        let clamped = min(max(value, ProfileMapLayout.zoomRange.lowerBound), ProfileMapLayout.zoomRange.upperBound)
        guard clamped != zoom else { return }
        zoom = clamped
        relayout()
    }

    func zoomBy(_ factor: Double) { setZoom(zoom * factor) }

    func pinchChanged(_ magnification: Double) {
        if pinchBase == nil { pinchBase = zoom }
        setZoom((pinchBase ?? zoom) * magnification)
    }

    func pinchEnded() { pinchBase = nil }

    private func relayout() {
        guard let profile else {
            layout = .empty(viewport: viewport)
            return
        }
        layout = ProfileMapLayout.make(profile: profile, index: index, selection: spaceSelection,
                                       viewport: viewport, zoom: zoom)
    }

    // MARK: Lookups

    func window(_ id: UUID) -> WindowSnapshot? { profile?.windows.first { $0.id == id } }

    /// The Space a monitor currently shows.
    func shownSpace(onDisplay uuid: String) -> ProfileSpaceIndex.Space? {
        let id = spaceSelection[uuid] ?? index.defaultSpaceID(displayUUID: uuid)
        return id.flatMap { index.space(id: $0) }
    }

    /// "Desktop 2", or the owner apps of a full-screen Space.
    func spaceName(_ space: ProfileSpaceIndex.Space) -> String {
        switch space.kind {
        case .desktop:
            return "Desktop \(space.desktopNumber ?? space.position + 1)"
        case .fullScreen:
            let names = space.fullScreenWindowIDs.compactMap { window($0)?.app.name }
            return names.isEmpty ? "Full-screen Space" : "Full screen: " + names.joined(separator: " and ")
        case .other:
            return "Space \(space.position + 1)"
        }
    }

    // MARK: Selection

    func setHover(_ tileID: String, inside: Bool) {
        if inside { hoveredTileID = tileID } else if hoveredTileID == tileID { hoveredTileID = nil }
    }

    func selectSpace(_ id: String) {
        guard let space = index.space(id: id) else { return }
        spaceSelection[space.displayUUID] = id
        focusedDisplayUUID = space.displayUUID
        relayout()
        if let selectedWindowID, !layout.windows.contains(where: { $0.windowID == selectedWindowID }) {
            self.selectedWindowID = nil
        }
    }

    func selectWindow(_ id: UUID?) {
        selectedWindowID = id
        if let id, let tile = layout.windows.first(where: { $0.windowID == id }) {
            focusedDisplayUUID = tile.displayUUID
        }
    }

    /// Tab / Shift+Tab: the next Space across all monitors, wrapping around.
    func stepSpace(forward: Bool) {
        let ordered = layout.monitors.flatMap { index.spaces(onDisplay: $0.id) }
        guard !ordered.isEmpty else { return }
        let currentID = focusedDisplayUUID.flatMap { shownSpace(onDisplay: $0)?.id }
        let at = ordered.firstIndex { $0.id == currentID } ?? (forward ? -1 : 0)
        let next = (at + (forward ? 1 : -1) + ordered.count) % ordered.count
        selectSpace(ordered[next].id)
    }

    /// Arrow keys: the nearest window in that direction; the front window when nothing is selected.
    func moveSelection(_ direction: MapDirection) {
        let tiles = layout.windows
        guard !tiles.isEmpty else { return }
        guard let current = tiles.first(where: { $0.windowID == selectedWindowID }) else {
            selectWindow(tiles.min { $0.zIndex < $1.zIndex }?.windowID)
            return
        }
        let origin = CGPoint(x: current.rect.midX, y: current.rect.midY)
        var best: (id: UUID, score: CGFloat)?
        for tile in tiles where tile.windowID != current.windowID {
            let dx = tile.rect.midX - origin.x
            let dy = tile.rect.midY - origin.y
            let along: CGFloat, across: CGFloat
            switch direction {
            case .left: (along, across) = (-dx, dy)
            case .right: (along, across) = (dx, dy)
            case .up: (along, across) = (-dy, dx)
            case .down: (along, across) = (dy, dx)
            }
            guard along > 0.5 else { continue }
            let score = along + 2 * abs(across)
            if best == nil || score < best!.score { best = (tile.windowID, score) }
        }
        if let best { selectWindow(best.id) }
    }

    // MARK: Text

    /// "on the left half", "full screen", and so on, or nil.
    static func positionPhrase(for window: WindowSnapshot, tile: ProfileMapLayout.WindowTile?) -> String? {
        if tile?.isFullScreen == true || window.isFullScreen { return tile?.isSplitHalf == true ? "one half of a Split View Space" : "full screen" }
        let r = window.relativeFrame
        let near: (CGFloat, CGFloat) -> Bool = { abs($0 - $1) < 0.03 }
        if near(r.width, 0.5), near(r.height, 1) {
            if near(r.minX, 0) { return "on the left half" }
            if near(r.minX, 0.5) { return "on the right half" }
        }
        if near(r.height, 0.5), near(r.width, 1) {
            if near(r.minY, 0) { return "on the top half" }
            if near(r.minY, 0.5) { return "on the bottom half" }
        }
        return nil
    }

    static func statusText(_ status: WindowLiveStatus) -> String {
        switch status {
        case .inPlace: return "in place"
        case .willMove: return "will be moved"
        case .willLaunch: return "app will launch"
        case .notFound(let reason): return reason.isEmpty ? "not found" : "not found: \(reason)"
        case .notRestored: return "not restored"
        }
    }

    /// The single-line summary above the map, or nil without status.
    var summaryText: String? {
        guard let s = status?.summary else { return nil }
        var parts: [String] = []
        if s.inPlace > 0 { parts.append("\(s.inPlace) in place") }
        if s.willMove > 0 { parts.append("\(s.willMove) will move") }
        if s.appsToLaunch > 0 { parts.append("\(s.appsToLaunch) app\(s.appsToLaunch == 1 ? "" : "s") will launch") }
        if s.notFound > 0 { parts.append("\(s.notFound) not found") }
        if s.notRestored > 0 { parts.append("\(s.notRestored) not restored") }
        if s.missingDesktops > 0 { parts.append("\(s.missingDesktops) Desktop\(s.missingDesktops == 1 ? "" : "s") missing") }
        return parts.isEmpty ? "Nothing to restore" : parts.joined(separator: ", ")
    }
}

extension Profile {
    /// A profile with no content, so the model never holds an optional index.
    static var emptyForMap: Profile {
        Profile(name: "", monitorSetKey: "")
    }
}
