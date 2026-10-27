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
    /// View scale of the whole map (1 = fitted). `layout` is always the zoom-1 canvas (edits, snapping and hit tests
    /// work in it); `displayLayout` is the same geometry multiplied by the zoom, so the vector map is redrawn sharp.
    @Published private(set) var zoom: Double = 1
    /// Screen position of the canvas origin inside the viewport (pan). See `CanvasViewport`.
    @Published private(set) var offset: CGPoint = .zero
    /// True while Space is held over the map: the canvas ignores clicks so a drag pans instead of moving windows.
    @Published var panModeActive = false
    @Published private(set) var viewport: CGSize = CGSize(width: 800, height: 500)
    /// Optional live status ("Compare with now"). Nil hides every status badge.
    @Published var status: ProfileLiveStatus?
    @Published private(set) var layout: ProfileMapLayout = .empty(viewport: CGSize(width: 800, height: 500))
    /// Bumped whenever `layout` is rebuilt; with the zoom it keys the `displayLayout` cache.
    private var layoutRevision = 0
    private var displayCache: (revision: Int, zoom: Double, layout: ProfileMapLayout)?

    /// `WindowTile.id` under the pointer (hover highlight only).
    @Published private(set) var hoveredTileID: String?

    // MARK: Tile stacks (P6.56)

    /// Windows whose frames overlap heavily, per Space, from `TileStacking`. Includes single windows.
    @Published private(set) var stacks: [TileStacking.Stack] = []
    /// The window shown in front of a collapsed stack, by `Stack.id`. A stack missing here shows its real front window.
    @Published private(set) var frontOverride: [String: UUID] = [:]
    /// The stack whose windows are fanned out in a strip, by `Stack.id`.
    @Published private(set) var fannedStackID: String?
    /// View mode and Compare collapse a stack to one tile; Edit mode keeps every tile (editing needs them).
    /// Set by the canvas, not published: the canvas that sets it is the one that draws.
    var collapsesStacks = true

    // MARK: Loading

    func load(_ profile: Profile?) {
        let changed = self.profile?.id != profile?.id
        let oldIndex = index
        self.profile = profile
        index = ProfileSpaceIndex(profile: profile ?? Profile.emptyForMap)
        if changed {
            spaceSelection = [:]
            selectedWindowID = nil
            frontOverride = [:]
            fannedStackID = nil
            zoom = 1
            offset = .zero
            focusedDisplayUUID = profile?.displays.first?.uuid
        } else {
            // Space ids are positional, so re-resolve each stored selection by kind + Desktop number
            // (or the owner windows of a full-screen Space) and drop the ones that no longer exist.
            var resolved: [String: String] = [:]
            for (display, id) in spaceSelection {
                guard let old = oldIndex.space(id: id) else { continue }
                let match = index.spaces.first { s in
                    guard s.displayUUID == display, s.kind == old.kind else { return false }
                    switch old.kind {
                    case .desktop: return s.desktopNumber == old.desktopNumber
                    case .fullScreen: return !old.fullScreenWindowIDs.isEmpty && s.fullScreenWindowIDs == old.fullScreenWindowIDs
                    case .other: return s.position == old.position
                    }
                }
                if let match { resolved[display] = match.id }
            }
            spaceSelection = resolved
            if let focus = focusedDisplayUUID, !(profile?.displays.contains { $0.uuid == focus } ?? false) {
                focusedDisplayUUID = profile?.displays.first?.uuid
            }
        }
        relayout()
    }

    // MARK: Layout

    /// The canvas to screen transform. The ONE place canvas points and viewport points are converted:
    /// `canvas.toScreen` / `canvas.toCanvas`.
    var canvas: CanvasViewport { CanvasViewport(zoom: zoom, offset: offset) }

    /// Same scale without the pan: converts to and from the canvas content's own local space (gesture and drop locations).
    var canvasLocal: CanvasViewport { CanvasViewport(zoom: zoom) }

    /// `layout` with every frame multiplied by the zoom, cached per (layout revision, zoom): a redraw at an unchanged
    /// zoom (hover, selection) costs nothing, and a pinch step builds it once.
    var displayLayout: ProfileMapLayout {
        if let hit = displayCache, hit.revision == layoutRevision, hit.zoom == zoom { return hit.layout }
        let scaled = layout.scaled(by: zoom)
        displayCache = (layoutRevision, zoom, scaled)
        return scaled
    }

    func setViewport(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != viewport else { return }
        viewport = size
        relayout()
    }

    /// Zooms to `value` (clamped) keeping the point under `anchor` (viewport coordinates; default the centre) fixed.
    func setZoom(_ value: Double, around anchor: CGPoint? = nil) {
        let point = anchor ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        apply(CanvasViewport(zoom: zoom, offset: offset).zoomed(to: value, around: point))
    }

    func zoomBy(_ factor: Double, around anchor: CGPoint? = nil) { setZoom(zoom * factor, around: anchor) }

    /// Moves the map by `delta` screen points (two-finger scroll, Space+drag, middle mouse).
    func panBy(_ delta: CGSize) {
        apply(CanvasViewport(zoom: zoom, offset: offset).panned(by: delta))
    }

    /// Fit: the whole canvas at once, recentred.
    func fit() {
        apply(CanvasViewport.fitting(CGRect(origin: .zero, size: layout.canvasSize), in: viewport, padding: 0, maxZoom: 1),
              clamp: false)
        DebugLog.log("studio", "map fit")
    }

    /// 100%: the fitted scale, keeping the centre of the view where it is.
    func actualSize() { setZoom(1) }

    /// Zoom to the selected window, else the shown Space of the focused monitor.
    func zoomToSelection() {
        let rect: CGRect?
        if let selectedWindowID, let tile = layout.windows.first(where: { $0.windowID == selectedWindowID }) {
            rect = tile.rect
        } else {
            let uuid = focusedDisplayUUID ?? layout.monitors.first?.id
            rect = layout.monitors.first { $0.id == uuid }?.contentRect
        }
        guard let rect else { return }
        apply(CanvasViewport.fitting(rect, in: viewport, padding: 48), clamp: false)
        DebugLog.log("studio", "map zoom to selection \(Int((zoom * 100).rounded()))%")
    }

    private func apply(_ next: CanvasViewport, clamp: Bool = true) {
        let result = clamp ? next.clamped(content: layout.canvasSize, viewport: viewport) : next
        if result.zoom != zoom { zoom = result.zoom }
        if result.offset != offset { offset = result.offset }
    }

    private func relayout() {
        layoutRevision += 1
        guard let profile else {
            layout = .empty(viewport: viewport)
            return
        }
        layout = ProfileMapLayout.make(profile: profile, index: index, selection: spaceSelection,
                                       viewport: viewport, zoom: 1)
        regroupStacks(profile)
    }

    private func regroupStacks(_ profile: Profile) {
        let apps = Dictionary(profile.windows.map { ($0.id, $0.app.bundleID ?? $0.app.name) }, uniquingKeysWith: { a, _ in a })
        stacks = TileStacking.group(layout.windows.map {
            TileStacking.Item(windowID: $0.windowID, spaceID: $0.spaceID, rect: $0.rect, zIndex: $0.zIndex,
                              appKey: apps[$0.windowID] ?? "")
        }).filter(\.isStack)
        let live = Set(stacks.map(\.id))
        frontOverride = frontOverride.filter { live.contains($0.key) && stack(withID: $0.key)?.members.contains($0.value) == true }
        if let fannedStackID, !live.contains(fannedStackID) { self.fannedStackID = nil }
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
        // Selecting a hidden member (inspector list, tray, fan) brings it to the front of its stack.
        if let id {
            for stack in stacks where stack.members.contains(id) { frontOverride[stack.id] = id }
        }
        if let fannedStackID, let id, stack(withID: fannedStackID)?.members.contains(id) != true { self.fannedStackID = nil }
        if id == nil { fannedStackID = nil }
    }

    // MARK: Stack lookups and actions

    func stack(withID id: String) -> TileStacking.Stack? { stacks.first { $0.id == id } }

    func stack(containing windowID: UUID, spaceID: String? = nil) -> TileStacking.Stack? {
        stacks.first { $0.members.contains(windowID) && (spaceID == nil || $0.spaceID == spaceID) }
    }

    /// The stack the selected window belongs to (on the Space it is shown on).
    var selectedStack: TileStacking.Stack? {
        guard let selectedWindowID else { return nil }
        let shown = Set(layout.windows.filter { $0.windowID == selectedWindowID }.map(\.spaceID))
        return stacks.first { $0.members.contains(selectedWindowID) && shown.contains($0.spaceID) }
    }

    /// The member drawn in front while the stack is collapsed.
    func frontWindowID(of stack: TileStacking.Stack) -> UUID {
        frontOverride[stack.id].flatMap { stack.members.contains($0) ? $0 : nil } ?? stack.members[0]
    }

    /// Members with the front one first, the rest in stacking order.
    func orderedMembers(of stack: TileStacking.Stack) -> [UUID] {
        let front = frontWindowID(of: stack)
        return [front] + stack.members.filter { $0 != front }
    }

    /// Tiles (`WindowTile.id`) that a collapsed stack hides behind its front window.
    var hiddenTileIDs: Set<String> {
        guard collapsesStacks else { return [] }
        var hidden = Set<String>()
        for stack in stacks {
            let front = frontWindowID(of: stack)
            for member in stack.members where member != front { hidden.insert("\(stack.spaceID)#\(member.uuidString)") }
        }
        return hidden
    }

    /// The stack a tile is the visible front of (collapsed), or the top tile of (Edit mode, badge only).
    func stackShown(by tile: ProfileMapLayout.WindowTile) -> TileStacking.Stack? {
        guard let stack = stack(containing: tile.windowID, spaceID: tile.spaceID) else { return nil }
        return (collapsesStacks ? frontWindowID(of: stack) : stack.members[0]) == tile.windowID ? stack : nil
    }

    /// Click on a collapsed stack: select its front window and fan the windows out.
    func fanOut(_ stack: TileStacking.Stack) {
        selectWindow(frontWindowID(of: stack))
        fannedStackID = stack.id
        DebugLog.log("studio", "stack fan out \(stack.count) windows (\(stack.appKey))")
    }

    /// Esc: closes the fan. False when nothing was open, so the key falls through.
    @discardableResult func collapseFan() -> Bool {
        guard fannedStackID != nil else { return false }
        fannedStackID = nil
        DebugLog.log("studio", "stack collapse")
        return true
    }

    /// Option-click or the badge: the next window of the stack comes to the front.
    func cycleFront(_ stack: TileStacking.Stack) {
        let at = stack.members.firstIndex(of: frontWindowID(of: stack)) ?? 0
        let next = stack.members[(at + 1) % stack.members.count]
        frontOverride[stack.id] = next
        if let selectedWindowID, stack.members.contains(selectedWindowID) { self.selectedWindowID = next }
        DebugLog.log("studio", "stack cycle front \(stack.count) windows")
    }

    /// Arrow keys while a fan is open: the previous or next window of that stack.
    private func stepFan(_ direction: MapDirection) -> Bool {
        guard collapsesStacks, let fannedStackID, let stack = stack(withID: fannedStackID) else { return false }
        let members = stack.members
        let at = members.firstIndex { $0 == selectedWindowID } ?? members.firstIndex(of: frontWindowID(of: stack)) ?? 0
        let delta = (direction == .left || direction == .up) ? -1 : 1
        selectWindow(members[(at + delta + members.count) % members.count])
        return true
    }

    /// Return: fan out the stack of the selected window.
    @discardableResult func fanOutSelected() -> Bool {
        guard collapsesStacks, let stack = selectedStack else { return false }
        fanOut(stack)
        return true
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
        if stepFan(direction) { return }
        let hidden = hiddenTileIDs
        let tiles = layout.windows.filter { !hidden.contains($0.id) }
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
