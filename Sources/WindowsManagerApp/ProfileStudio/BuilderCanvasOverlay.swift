import AppKit
import Combine
import SwiftUI
import WMCore

// Edit mode on the profile map (UI5): drop apps, drag and resize window tiles, snap to Layout zones,
// keyboard nudge / delete, and the Desktop strip controls. All edits go through ProfileBuilderModel;
// a drag is committed once, when it ends (one undo entry), while its preview is drawn here.

/// A drag in progress, in canvas coordinates.
struct BuilderDragPreview: Equatable {
    enum Kind: Equatable { case move, resize(ResizeHandle) }
    var windowID: UUID
    var kind: Kind
    var startRect: CGRect
    var rect: CGRect
    var displayUUID: String
    var sourceDisplayUUID: String
    var zoneName: String?
    /// Set while the pointer is over a Space thumbnail (a drop there moves the window to that Space).
    var thumbnailSpaceID: String?
    /// Magnet guide lines the rect is stuck to, canvas points.
    var guides: [MagnetSnap.Guide] = []
    /// Neighbour tiles resized along with the dragged one (Link, G5), canvas points.
    var linked: [UUID: CGRect] = [:]
}

@MainActor
final class BuilderCanvasController: ObservableObject {
    let map: ProfileMapModel
    let builder: ProfileBuilderModel

    @Published var snapEnabled = true
    /// Magnet mode (G3): edges stick to monitor and tile edges while dragging, with guide lines.
    @Published var magnetEnabled = false
    /// Linked resize (G5): resizing a shared edge also resizes the touching neighbour.
    @Published var linkEnabled = false
    /// Allow overlap (G5): off (default) keeps tiles apart and inside the monitor while dragging and resizing.
    @Published var allowOverlap = false
    /// Gap between tiles for Auto layout (G4), canvas points.
    @Published var autoLayoutGap: CGFloat = AutoLayout.defaultGap
    /// Per-monitor grid settings (G1, G2), kept per Studio in UserDefaults.
    @Published private(set) var grids: [String: MonitorGrid] = MonitorGrid.loadAll()
    @Published private(set) var layouts: [WMCore.Layout] = []
    @Published private(set) var chosenLayout: [String: UUID] = [:]
    @Published private(set) var drag: BuilderDragPreview?
    @Published var isDropTargeted = false
    /// Monitor whose zone editor sheet is open.
    @Published var zoneEditorMonitor: String?

    private var noLayout: Set<String> = []
    private var dragCancelled = false
    private var cancellables: Set<AnyCancellable> = []

    init(map: ProfileMapModel, builder: ProfileBuilderModel) {
        self.map = map
        self.builder = builder
        layouts = (try? LayoutStore().load()) ?? []
        builder.$session.sink { [weak self] session in
            guard let self else { return }
            self.map.load(session?.profile)
            if let id = self.builder.selectedWindowID, session?.profile.windows.contains(where: { $0.id == id }) == true {
                self.reveal(windowID: id, in: session?.profile)
            }
        }.store(in: &cancellables)
        builder.$selectedWindowID.removeDuplicates().sink { [weak self] id in
            guard let self else { return }
            if self.map.selectedWindowID != id { self.map.selectWindow(id) }
            if let id { self.reveal(windowID: id, in: self.builder.profile) }
        }.store(in: &cancellables)
        builder.$selectedDesktop.removeDuplicates().sink { [weak self] number in
            guard let self, let number, let display = self.builder.selectedDisplayUUID else { return }
            if let space = self.map.index.spaces(onDisplay: display).first(where: { $0.kind == .desktop && $0.desktopNumber == number }),
               self.map.shownSpace(onDisplay: display)?.id != space.id {
                self.map.selectSpace(space.id)
            }
        }.store(in: &cancellables)
        map.load(builder.profile)
    }

    // MARK: Grid

    struct MonitorGrid: Codable, Equatable {
        var isOn = false
        var spec = GridSpec.medium

        private static let key = "studio.builder.monitorGrids"
        static func loadAll() -> [String: MonitorGrid] {
            UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: MonitorGrid].self, from: $0) } ?? [:]
        }
        static func save(_ grids: [String: MonitorGrid]) {
            if let data = try? JSONEncoder().encode(grids) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    func grid(_ display: String) -> MonitorGrid { grids[display] ?? MonitorGrid() }

    func setGrid(_ display: String, _ change: (inout MonitorGrid) -> Void) {
        var g = grid(display)
        change(&g)
        grids[display] = g
        MonitorGrid.save(grids)
    }

    private var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }

    private var magnetThreshold: CGFloat { MagnetSnap.canvasThreshold(zoom: map.canvasLocal.zoom) }

    // MARK: Zones

    var snapOptionDisabled: Bool { !snapEnabled || NSEvent.modifierFlags.contains(.option) }

    func layoutsMatching(_ display: String) -> [WMCore.Layout] {
        guard let identity = builder.profile?.displays.first(where: { $0.uuid == display }) else { return [] }
        return layouts.filter { $0.matches(display: identity) }
    }

    /// The Layout used for snapping on a monitor: the chosen one, else the one saved for exactly this display.
    func activeLayout(_ display: String) -> WMCore.Layout? {
        if noLayout.contains(display) { return nil }
        let matching = layoutsMatching(display)
        if let id = chosenLayout[display] { return matching.first { $0.id == id } }
        return matching.first { $0.displayKey != nil }
    }

    func chooseLayout(_ id: UUID?, on display: String) {
        if let id { chosenLayout[display] = id; noLayout.remove(display) } else { chosenLayout[display] = nil; noLayout.insert(display) }
        objectWillChange.send()
    }

    func reloadLayouts() {
        layouts = (try? LayoutStore().load()) ?? []
        objectWillChange.send()
    }

    /// Saves the tile frames on this monitor's shown Desktop as a new Layout zone preset (saved layouts elsewhere stay untouched).
    @discardableResult
    func saveArrangementAsZones(on monitor: ProfileMapLayout.Monitor, name: String) -> Bool {
        let shown = map.shownSpace(onDisplay: monitor.id)?.id
        let tiles = map.layout.windows.filter { $0.displayUUID == monitor.id && !$0.isFullScreen && (shown == nil || $0.spaceID == shown) }
        let f = monitor.contentRect
        guard !tiles.isEmpty, f.width > 0, f.height > 0 else { return false }
        let zones: [Zone] = tiles.enumerated().compactMap { index, tile in
            let r = tile.rect.intersection(f)
            guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
            let nr = NormalizedRect(x: (r.minX - f.minX) / f.width, y: (r.minY - f.minY) / f.height,
                                    width: r.width / f.width, height: r.height / f.height)
            return Zone(name: "Zone \(index + 1)", rect: nr)
        }
        guard !zones.isEmpty else { return false }
        var all = (try? LayoutStore().load()) ?? []
        let layout = WMCore.Layout(name: name, displayKey: monitor.id, zones: zones)
        all.append(layout)
        guard (try? LayoutStore().save(all)) != nil else { return false }
        reloadLayouts()
        chooseLayout(layout.id, on: monitor.id)
        return true
    }

    /// Places the shown Desktop's tiles into a layout's zones, in order (reading order of the tiles' current positions).
    func applyZones(_ layout: WMCore.Layout, on monitor: ProfileMapLayout.Monitor) {
        let shown = map.shownSpace(onDisplay: monitor.id)?.id
        let tiles = map.layout.windows
            .filter { $0.displayUUID == monitor.id && !$0.isFullScreen && (shown == nil || $0.spaceID == shown) }
            .sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
        guard !tiles.isEmpty, !layout.zones.isEmpty else { return }
        let f = monitor.contentRect
        chooseLayout(layout.id, on: monitor.id)
        builder.edit(kind: nil) { editor in
            for (tile, zone) in zip(tiles, layout.zones) {
                let r = CGRect(x: f.minX + zone.rect.x * f.width, y: f.minY + zone.rect.y * f.height,
                               width: zone.rect.width * f.width, height: zone.rect.height * f.height)
                try editor.setRelativeFrame(ofWindow: tile.windowID, relativeFrame: MapSnapping.relativeFrame(of: r, in: f))
            }
        }
    }

    /// Zone rects in canvas points, inside the monitor's visible part.
    func zones(on monitor: ProfileMapLayout.Monitor) -> [(name: String, rect: CGRect)] {
        guard let layout = activeLayout(monitor.id) else { return [] }
        let f = monitor.contentRect
        return layout.zones.compactMap { zone in
            let r = CGRect(x: f.minX + zone.rect.x * f.width, y: f.minY + zone.rect.y * f.height,
                           width: zone.rect.width * f.width, height: zone.rect.height * f.height)
                .intersection(monitor.contentRect)
            return r.isNull || r.width < 1 || r.height < 1 ? nil : (zone.name, r)
        }
    }

    // MARK: Lookups

    func monitor(_ id: String) -> ProfileMapLayout.Monitor? { map.layout.monitors.first { $0.id == id } }

    func window(_ id: UUID) -> WindowSnapshot? { builder.profile?.windows.first { $0.id == id } }

    private func otherEdges(on display: String, excluding id: UUID) -> [CGRect] {
        map.layout.windows.filter { $0.displayUUID == display && $0.windowID != id && !$0.isFullScreen }.map(\.rect)
    }

    /// The Desktop number a window dropped on `display` goes to: the shown Desktop, else the selected, else the first.
    func desktopNumber(onDisplay display: String) -> Int? {
        if let shown = map.shownSpace(onDisplay: display), shown.kind == .desktop, let n = shown.desktopNumber { return n }
        let desktops = map.index.spaces(onDisplay: display).filter { $0.kind == .desktop }.compactMap(\.desktopNumber)
        if builder.selectedDisplayUUID == display, let n = builder.selectedDesktop, desktops.contains(n) { return n }
        return desktops.min()
    }

    // MARK: Selection

    func select(_ id: UUID?, display: String? = nil) {
        map.selectWindow(id)
        builder.selectedWindowID = id
        if let display { builder.selectedDisplayUUID = display }
    }

    func selectSpace(_ space: ProfileSpaceIndex.Space) {
        map.selectSpace(space.id)
        builder.selectedDisplayUUID = space.displayUUID
        if space.kind == .desktop, let n = space.desktopNumber { builder.selectedDesktop = n }
        if let id = builder.selectedWindowID, !space.windowIDs.contains(id) { builder.selectedWindowID = nil }
    }

    /// Shows the Space that holds the window when the shown one does not (after an edit or an undo).
    private func reveal(windowID: UUID, in profile: Profile?) {
        guard !map.layout.windows.contains(where: { $0.windowID == windowID }) else { return }
        guard let space = map.index.spaces.first(where: { $0.windowIDs.contains(windowID) }) else { return }
        map.selectSpace(space.id)
        map.selectWindow(windowID)
        builder.selectedDisplayUUID = space.displayUUID
        if space.kind == .desktop, let n = space.desktopNumber { builder.selectedDesktop = n }
    }

    // MARK: Moving

    func moveChanged(tile: ProfileMapLayout.WindowTile, translation: CGSize, pointer: CGPoint) {
        guard !dragCancelled, !tile.isFullScreen else { return }
        if drag == nil || drag?.windowID != tile.windowID {
            select(tile.windowID, display: tile.displayUUID)
            drag = BuilderDragPreview(windowID: tile.windowID, kind: .move, startRect: tile.rect, rect: tile.rect,
                                      displayUUID: tile.displayUUID, sourceDisplayUUID: tile.displayUUID,
                                      zoneName: nil, thumbnailSpaceID: nil)
        }
        guard var preview = drag, let source = monitor(tile.displayUUID) else { return }
        var rect = preview.startRect.offsetBy(dx: translation.width, dy: translation.height)

        if let thumb = map.layout.thumbnails.first(where: { $0.rect.contains(pointer) }) {
            preview.thumbnailSpaceID = thumb.id
            preview.rect = rect
            preview.zoneName = nil
            preview.displayUUID = thumb.displayUUID
            drag = preview
            return
        }
        preview.thumbnailSpaceID = nil
        let target = map.layout.monitors.first { $0.frame.contains(pointer) } ?? source
        if target.id != source.id {
            let relative = MapSnapping.relativeFrame(of: preview.startRect, in: source.contentRect)
            let size = MapSnapping.canvasRect(forRelative: CGRect(x: 0, y: 0, width: relative.width, height: relative.height),
                                              in: CGRect(origin: .zero, size: target.contentRect.size)).size
            rect = CGRect(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2, width: size.width, height: size.height)
        }
        let result = MapSnapping.snap(rect: rect, in: target.contentRect, zones: zones(on: target),
                                      edges: otherEdges(on: target.id, excluding: tile.windowID),
                                      option: MapSnapping.SnapOptions(disabled: snapOptionDisabled))
        var snapped = result.rect
        preview.guides = []
        if result.zoneName == nil, !optionHeld {
            let g = grid(target.id)
            if g.isOn { snapped = GridSnap.snapMove(snapped, spec: g.spec, in: target.contentRect) }
            if magnetEnabled {
                let m = MagnetSnap.snapMove(snapped, monitor: target.contentRect,
                                            others: otherEdges(on: target.id, excluding: tile.windowID), threshold: magnetThreshold)
                snapped = m.rect
                preview.guides = m.guides
            }
        }
        if !allowOverlap {
            snapped = OverlapLock.constrainMove(snapped, monitor: target.contentRect,
                                                others: otherEdges(on: target.id, excluding: tile.windowID),
                                                fallback: preview.rect.size == snapped.size && target.id == preview.displayUUID ? preview.rect : tile.rect)
        }
        preview.rect = snapped
        preview.zoneName = result.zoneName
        preview.displayUUID = target.id
        drag = preview
    }

    /// `rect` (screen points of the map) held to the window's min / max size, scaled from the real frame to the tile.
    private func clampDrag(_ rect: CGRect, limits: WindowResizeLimits, window: WindowSnapshot,
                           tile: ProfileMapLayout.WindowTile, handle: ResizeHandle) -> CGRect {
        guard window.frame.width > 0, window.frame.height > 0, tile.rect.width > 0, tile.rect.height > 0 else { return rect }
        let sx = tile.rect.width / window.frame.width, sy = tile.rect.height / window.frame.height
        var out = rect
        func axis(_ size: CGFloat, lo: CGFloat?, hi: CGFloat?, scale: CGFloat) -> CGFloat {
            var s = size
            if let lo, lo > 0 { s = Swift.max(s, lo * scale) }
            if let hi, hi < .greatestFiniteMagnitude / 2 { s = Swift.min(s, hi * scale) }
            return s
        }
        let w = axis(rect.width, lo: limits.minSize?.width, hi: limits.maxSize?.width, scale: sx)
        let h = axis(rect.height, lo: limits.minSize?.height, hi: limits.maxSize?.height, scale: sy)
        if handle.movesLeft { out.origin.x = rect.maxX - w }
        if handle.movesTop { out.origin.y = rect.maxY - h }
        out.size = CGSize(width: w, height: h)
        return out
    }

    func resizeChanged(tile: ProfileMapLayout.WindowTile, handle: ResizeHandle, translation: CGSize) {
        guard !dragCancelled, !tile.isFullScreen, let monitor = monitor(tile.displayUUID) else { return }
        if drag == nil || drag?.windowID != tile.windowID {
            select(tile.windowID, display: tile.displayUUID)
            drag = BuilderDragPreview(windowID: tile.windowID, kind: .resize(handle), startRect: tile.rect, rect: tile.rect,
                                      displayUUID: tile.displayUUID, sourceDisplayUUID: tile.displayUUID,
                                      zoneName: nil, thumbnailSpaceID: nil)
        }
        guard var preview = drag else { return }
        let minSize = CGSize(width: MapSnapping.minimumWidth, height: MapSnapping.minimumHeight)
        // A fixed width / height cannot be dragged; min / max (known or learned) are held during the drag too.
        var translation = translation
        let limits = window(tile.windowID).flatMap { SizeLimitLearning.effectiveLimits(for: $0) }
        if let limits {
            if limits.fixedWidth { translation.width = 0 }
            if limits.fixedHeight { translation.height = 0 }
        }
        var rect = ResizeHandles.resize(preview.startRect, handle: handle, by: translation, minSize: minSize,
                                        within: monitor.contentRect)
        if let limits, limits.hasRestrictions, let w = window(tile.windowID) {
            rect = clampDrag(rect, limits: limits, window: w, tile: tile, handle: handle)
        }
        if !snapOptionDisabled {
            let zoneRects = zones(on: monitor).map(\.rect)
            let others = otherEdges(on: monitor.id, excluding: tile.windowID)
            let xLines = [monitor.contentRect.minX, monitor.contentRect.maxX]
                + others.flatMap { [$0.minX, $0.maxX] } + zoneRects.flatMap { [$0.minX, $0.maxX] }
            let yLines = [monitor.contentRect.minY, monitor.contentRect.maxY]
                + others.flatMap { [$0.minY, $0.maxY] } + zoneRects.flatMap { [$0.minY, $0.maxY] }
            rect = ResizeHandles.snapMovingEdges(rect, handle: handle, xLines: xLines, yLines: yLines,
                                                 threshold: MapSnapping.defaultThreshold, minSize: minSize)
            rect = rect.intersection(monitor.contentRect)
        }
        preview.guides = []
        if !optionHeld {
            let g = grid(monitor.id)
            if g.isOn { rect = GridSnap.snapResize(rect, handle: handle, spec: g.spec, in: monitor.contentRect, minSize: minSize) }
            if magnetEnabled {
                let m = MagnetSnap.snapResize(rect, handle: handle, monitor: monitor.contentRect,
                                              others: otherEdges(on: monitor.id, excluding: tile.windowID),
                                              threshold: magnetThreshold, minSize: minSize)
                rect = m.rect
                preview.guides = m.guides
            }
        }
        preview.linked = [:]
        if !allowOverlap || linkEnabled {
            let neighbours = map.layout.windows
                .filter { $0.displayUUID == monitor.id && $0.windowID != tile.windowID && !$0.isFullScreen }
                .map { LinkedResize.Neighbour(id: $0.windowID, rect: $0.rect) }
            var linkedIDs: Set<UUID> = []
            if linkEnabled {
                let sides: [(Bool, LinkedResize.Side)] = [(handle.movesLeft, .left), (handle.movesRight, .right),
                                                          (handle.movesTop, .top), (handle.movesBottom, .bottom)]
                for (moves, side) in sides where moves {
                    linkedIDs.formUnion(LinkedResize.sharedEdge(of: preview.startRect, side: side, among: neighbours).map(\.id))
                }
            }
            if !allowOverlap {
                rect = OverlapLock.constrainResize(rect, start: preview.startRect, handle: handle, monitor: monitor.contentRect,
                                                   others: neighbours.filter { !linkedIDs.contains($0.id) }.map(\.rect),
                                                   minSize: minSize)
            }
            if linkEnabled {
                let linked = LinkedResize.apply(start: preview.startRect, proposed: rect, handle: handle,
                                                neighbours: neighbours.filter { linkedIDs.contains($0.id) },
                                                minSize: minSize)
                rect = linked.rect
                preview.linked = linked.neighbours
            }
        }
        preview.rect = rect
        preview.zoneName = nil
        drag = preview
    }

    /// Commits the drag as one edit.
    func dragEnded() {
        defer { drag = nil; dragCancelled = false }
        guard !dragCancelled, let preview = drag, preview.rect != preview.startRect || preview.displayUUID != preview.sourceDisplayUUID
                || preview.thumbnailSpaceID != nil else { return }
        let id = preview.windowID
        switch preview.kind {
        case .resize:
            guard let monitor = monitor(preview.displayUUID) else { return }
            if preview.linked.isEmpty {
                builder.resizeWindow(id, to: MapSnapping.relativeFrame(of: preview.rect, in: monitor.contentRect), zoneName: nil)
            } else {
                builder.edit(kind: "linkedResize") { editor in
                    try editor.setRelativeFrame(ofWindow: id, relativeFrame: MapSnapping.relativeFrame(of: preview.rect, in: monitor.contentRect))
                    for (other, rect) in preview.linked {
                        try editor.setRelativeFrame(ofWindow: other, relativeFrame: MapSnapping.relativeFrame(of: rect, in: monitor.contentRect))
                    }
                }
            }
        case .move:
            if let spaceID = preview.thumbnailSpaceID {
                guard let space = map.index.space(id: spaceID) else { return }
                let number = space.kind == .desktop ? space.desktopNumber : desktopNumber(onDisplay: space.displayUUID)
                guard let number else { return }
                if let w = window(id), w.displayUUID == space.displayUUID, w.placement == .desktop(number: number) { return }
                builder.moveWindow(id, toDisplay: space.displayUUID, desktop: number)
                return
            }
            guard let monitor = monitor(preview.displayUUID) else { return }
            let relative = MapSnapping.relativeFrame(of: preview.rect, in: monitor.contentRect)
            if preview.displayUUID != preview.sourceDisplayUUID {
                guard let number = desktopNumber(onDisplay: preview.displayUUID) else { return }
                builder.edit(kind: "moveWindowToSpace") { editor in
                    try editor.moveWindow(id, toDisplay: preview.displayUUID, desktop: number)
                    try editor.setRelativeFrame(ofWindow: id, relativeFrame: relative, zoneName: preview.zoneName)
                }
            } else {
                builder.moveWindow(id, to: relative, zoneName: preview.zoneName)
            }
        }
    }

    func cancelDrag() {
        guard drag != nil else { return }
        dragCancelled = true
        drag = nil
    }

    // MARK: Auto layout (G4)

    /// Candidate layouts for the tiles of the shown Desktop on a monitor.
    func autoLayoutCandidates(on monitor: ProfileMapLayout.Monitor) -> [AutoLayout.Candidate] {
        let shown = map.shownSpace(onDisplay: monitor.id)?.id
        let items = map.layout.windows
            .filter { $0.displayUUID == monitor.id && !$0.isFullScreen && (shown == nil || $0.spaceID == shown) }
            .map { AutoLayout.Item(id: $0.windowID, bundleID: window($0.windowID)?.app.bundleID) }
        return AutoLayout.candidates(items: items, visible: monitor.contentRect, gap: autoLayoutGap)
    }

    /// Applies a candidate as one undoable edit.
    func applyAutoLayout(_ candidate: AutoLayout.Candidate, on monitor: ProfileMapLayout.Monitor) {
        builder.edit(kind: nil) { editor in
            for (id, rect) in candidate.frames {
                try editor.setRelativeFrame(ofWindow: id, relativeFrame: MapSnapping.relativeFrame(of: rect, in: monitor.contentRect))
            }
        }
    }

    // MARK: Drops

    /// Apps dropped from the library at a canvas point.
    func handleDrop(_ items: [LibraryDragPayload], at point: CGPoint) -> Bool {
        guard !items.isEmpty else { return false }
        if let thumb = map.layout.thumbnails.first(where: { $0.rect.contains(point) }), let space = map.index.space(id: thumb.id) {
            selectSpace(space)
            guard let number = space.kind == .desktop ? space.desktopNumber : desktopNumber(onDisplay: space.displayUUID) else { return false }
            for item in items { builder.addWindow(app: item.appRef, onDisplay: space.displayUUID, desktop: number) }
            return true
        }
        guard let monitor = map.layout.monitors.first(where: { $0.frame.contains(point) }),
              let number = desktopNumber(onDisplay: monitor.id) else { return false }
        for (offset, item) in items.enumerated() {
            let size = CGSize(width: monitor.contentRect.width * 0.5, height: monitor.contentRect.height * 0.7)
            let centered = CGRect(x: point.x - size.width / 2 + CGFloat(offset) * MapSnapping.cascadeOffset,
                                  y: point.y - size.height / 2 + CGFloat(offset) * MapSnapping.cascadeOffset,
                                  width: size.width, height: size.height)
            let others = otherEdges(on: monitor.id, excluding: UUID())
            let result = MapSnapping.snap(rect: centered, in: monitor.contentRect, zones: zones(on: monitor),
                                          edges: others, option: MapSnapping.SnapOptions(disabled: snapOptionDisabled))
            builder.addWindow(app: item.appRef, onDisplay: monitor.id, desktop: number,
                              relativeFrame: MapSnapping.relativeFrame(of: result.rect, in: monitor.contentRect),
                              zoneName: result.zoneName)
        }
        return true
    }

    // MARK: Keyboard

    /// Returns true when the key was used. Called by the canvas before its own key handling.
    func handleKey(_ press: KeyPress) -> Bool {
        if press.key == .escape { if drag != nil { cancelDrag(); return true }; return false }
        guard let id = builder.selectedWindowID, let window = window(id) else { return false }
        if press.modifiers.contains(.control) { return false }   // Control+arrows still move the selection

        switch press.key {
        case .delete, .deleteForward:
            remove(window)
            return true
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard !window.isFullScreen else { return true }
            let step: CGFloat = press.modifiers.contains(.shift) ? 0.05 : 0.01
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch press.key {
            case .leftArrow: dx = -step
            case .rightArrow: dx = step
            case .upArrow: dy = -step
            default: dy = step
            }
            if press.modifiers.contains(.option) {
                let content = monitor(window.displayUUID)?.contentRect ?? .zero
                let minSize = CGSize(width: content.width > 0 ? MapSnapping.minimumWidth / content.width : 0.05,
                                     height: content.height > 0 ? MapSnapping.minimumHeight / content.height : 0.05)
                builder.resizeWindow(id, to: ResizeHandles.resize(relative: window.relativeFrame, dw: dx, dh: dy, minSize: minSize))
            } else {
                builder.moveWindow(id, to: ResizeHandles.nudge(relative: window.relativeFrame, dx: dx, dy: dy))
            }
            return true
        default:
            if press.modifiers.contains(.command), let n = Int(press.characters), (1...9).contains(n) {
                snapToZone(n - 1, window: window)
                return true
            }
            return false
        }
    }

    private func snapToZone(_ index: Int, window: WindowSnapshot) {
        guard !window.isFullScreen, let monitor = monitor(window.displayUUID) else { return }
        let zones = zones(on: monitor)
        guard zones.indices.contains(index) else { return }
        builder.moveWindow(window.id, to: MapSnapping.relativeFrame(of: zones[index].rect, in: monitor.contentRect),
                           zoneName: zones[index].name)
    }

    /// Delete: planned windows go at once; captured ones ask first (remove, or just stop restoring them).
    func remove(_ window: WindowSnapshot) {
        if window.origin == .planned {
            builder.removeWindow(window.id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove this window from the profile?"
        alert.informativeText = "\(window.app.name) was captured from your Desktop. You can remove it, or keep it and only skip it when the profile runs."
        alert.addButton(withTitle: "Remove window")
        alert.addButton(withTitle: "Don't restore it")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: builder.removeWindow(window.id)
        case .alertSecondButtonReturn: builder.setRestore(false, forWindow: window.id)
        default: break
        }
    }

    // MARK: Desktops

    func toggleFullScreen(_ window: WindowSnapshot) {
        if window.isFullScreen {
            guard let space = map.index.spaces.first(where: { $0.kind == .fullScreen && $0.fullScreenWindowIDs.contains(window.id) }),
                  let number = desktopNumber(onDisplay: space.displayUUID) else { return }
            builder.removeFullScreenSpace(onDisplay: space.displayUUID, position: space.position,
                                          removal: .moveWindows(toDesktop: number))
        } else {
            builder.makeFullScreen(windowID: window.id, afterPosition: map.shownSpace(onDisplay: window.displayUUID)?.position)
        }
    }

    func canMove(_ space: ProfileSpaceIndex.Space, by delta: Int) -> Bool {
        let spaces = map.index.spaces(onDisplay: space.displayUUID)
        switch space.kind {
        case .desktop:
            let numbers = spaces.filter { $0.kind == .desktop }.compactMap(\.desktopNumber)
            guard let n = space.desktopNumber else { return false }
            return numbers.contains(n + delta)
        case .fullScreen:
            let list = spaces.filter { $0.kind == .fullScreen }
            guard let at = list.firstIndex(where: { $0.id == space.id }) else { return false }
            return list.indices.contains(at + delta)
        case .other:
            return false
        }
    }

    func move(_ space: ProfileSpaceIndex.Space, by delta: Int) {
        guard canMove(space, by: delta) else { return }
        switch space.kind {
        case .desktop:
            if let n = space.desktopNumber { builder.moveDesktop(onDisplay: space.displayUUID, number: n, toNumber: n + delta) }
        case .fullScreen:
            let list = map.index.spaces(onDisplay: space.displayUUID).filter { $0.kind == .fullScreen }
            if let at = list.firstIndex(where: { $0.id == space.id }) {
                builder.moveFullScreenSpace(onDisplay: space.displayUUID, position: space.position, toIndex: at + delta)
            }
        case .other:
            break
        }
    }

    func canDelete(_ space: ProfileSpaceIndex.Space) -> Bool {
        switch space.kind {
        case .desktop: return map.index.spaces(onDisplay: space.displayUUID).filter { $0.kind == .desktop }.count > 1
        case .fullScreen: return true
        case .other: return false
        }
    }

    func delete(_ space: ProfileSpaceIndex.Space) {
        guard canDelete(space) else { return }
        let desktops = map.index.spaces(onDisplay: space.displayUUID).filter { $0.kind == .desktop }.compactMap(\.desktopNumber)
        let name = map.spaceName(space)
        let count = space.kind == .desktop ? space.windowIDs.filter { id in
            window(id)?.placement == .desktop(number: space.desktopNumber ?? -1)
        }.count : space.fullScreenWindowIDs.count
        let ownNumber = space.desktopNumber
        guard let fallback = desktops.sorted().first(where: { $0 != ownNumber }) else { return }

        var moveWindows = true
        if count > 0 {
            let alert = NSAlert()
            alert.messageText = "Delete \(name)?"
            alert.informativeText = "It has \(count) window\(count == 1 ? "" : "s")."
            alert.addButton(withTitle: "Move \(count) window\(count == 1 ? "" : "s") to Desktop \(fallback)")
            alert.addButton(withTitle: "Delete windows")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: moveWindows = true
            case .alertSecondButtonReturn: moveWindows = false
            default: return
            }
        }
        switch space.kind {
        case .desktop:
            if let n = space.desktopNumber {
                builder.deleteDesktop(onDisplay: space.displayUUID, number: n, moveWindowsTo: moveWindows ? fallback : nil)
            }
        case .fullScreen:
            builder.removeFullScreenSpace(onDisplay: space.displayUUID, position: space.position,
                                          removal: moveWindows ? .moveWindows(toDesktop: fallback) : .deleteWindows)
        case .other:
            break
        }
    }
}

// MARK: - Overlay

/// Drawn over the monitors in the canvas. Fills the canvas size; empty areas fall through to the canvas.
/// The controller works in canvas (zoom-1) coordinates; this view draws at the zoomed size, so every rect goes
/// through `local.toScreen` and every gesture location or translation through `local.toCanvas`.
struct BuilderCanvasOverlay: View {
    @ObservedObject var controller: BuilderCanvasController
    @ObservedObject private var map: ProfileMapModel
    @ObservedObject private var builder: ProfileBuilderModel
    @Environment(\.canvasFocusRequest) private var requestFocus
    @Environment(\.canvasFitRequest) private var requestFit
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let space = "builderCanvas"

    /// Canvas <-> local (zoomed, unpanned) drawing space.
    private var local: CanvasViewport { map.canvasLocal }

    init(controller: BuilderCanvasController) {
        self.controller = controller
        _map = ObservedObject(wrappedValue: controller.map)
        _builder = ObservedObject(wrappedValue: controller.builder)
    }

    var body: some View {
        let layout = map.layout
        ZStack(alignment: .topLeading) {
            background
            ForEach(layout.monitors) { monitor in zoneOverlay(monitor) }
            ForEach(layout.monitors) { monitor in gridOverlay(monitor) }
            ForEach(layout.windows.sorted { $0.zIndex > $1.zIndex }) { tile in tileHitArea(tile) }
            if let tile = selectedTile { handles(for: tile).id(tile.windowID) }
            if let preview = controller.drag {
                ghost(preview); guideLines(preview)
                ForEach(preview.linked.sorted { $0.key.uuidString < $1.key.uuidString }, id: \.key) { _, rect in linkedGhost(rect) }
            }
            ForEach(layout.thumbnails) { thumb in thumbnailHitArea(thumb) }
        }
        .frame(width: local.toScreen(layout.canvasSize).width, height: local.toScreen(layout.canvasSize).height,
               alignment: .topLeading)
        .animation(reduceMotion ? nil : Motion.spring, value: builder.selectedWindowID)
        .coordinateSpace(name: Self.space)
    }

    // MARK: Layers

    private var background: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { requestFit() }
            .onTapGesture {
                controller.select(nil)
                requestFocus()
            }
            .dropDestination(for: LibraryDragPayload.self) { items, location in
                controller.handleDrop(items, at: local.toCanvas(location))
            } isTargeted: { controller.isDropTargeted = $0 }
            .overlay {
                if controller.isDropTargeted {
                    ForEach(map.layout.monitors) { monitor in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                            .frame(width: local.toScreen(monitor.frame).width, height: local.toScreen(monitor.frame).height)
                            .position(x: local.toScreen(monitor.frame).midX, y: local.toScreen(monitor.frame).midY)
                    }
                }
            }
            .accessibilityHidden(true)
    }

    private var selectedTile: ProfileMapLayout.WindowTile? {
        guard let id = builder.selectedWindowID else { return nil }
        return map.layout.windows.first { $0.windowID == id && !$0.isFullScreen }
    }

    /// Light zone outlines while dragging on a monitor; the zone under the dragged window is filled.
    @ViewBuilder private func zoneOverlay(_ monitor: ProfileMapLayout.Monitor) -> some View {
        if let preview = controller.drag, preview.displayUUID == monitor.id, preview.thumbnailSpaceID == nil,
           !controller.snapOptionDisabled || preview.zoneName != nil {
            ForEach(Array(controller.zones(on: monitor).enumerated()), id: \.offset) { _, zone in
                let active = zone.name == preview.zoneName
                let rect = local.toScreen(zone.rect)
                Rectangle()
                    .fill(Palette.accent.opacity(active ? 0.25 : 0.06))
                    .overlay(Rectangle().strokeBorder(Palette.accent.opacity(active ? 0.9 : 0.4),
                                                      style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The grid lines over a monitor's visible area (G1).
    @ViewBuilder private func gridOverlay(_ monitor: ProfileMapLayout.Monitor) -> some View {
        let g = controller.grid(monitor.id)
        if g.isOn {
            let content = monitor.contentRect
            let screen = local.toScreen(content)
            Path { path in
                for x in GridSnap.xLines(g.spec, in: content) {
                    let sx = local.toScreen(CGPoint(x: x, y: content.minY)).x
                    path.move(to: CGPoint(x: sx, y: screen.minY)); path.addLine(to: CGPoint(x: sx, y: screen.maxY))
                }
                for y in GridSnap.yLines(g.spec, in: content) {
                    let sy = local.toScreen(CGPoint(x: content.minX, y: y)).y
                    path.move(to: CGPoint(x: screen.minX, y: sy)); path.addLine(to: CGPoint(x: screen.maxX, y: sy))
                }
            }
            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Magnet guide lines across the monitor the dragged tile is over (G3).
    @ViewBuilder private func guideLines(_ preview: BuilderDragPreview) -> some View {
        if !preview.guides.isEmpty, let monitor = controller.monitor(preview.displayUUID) {
            let screen = local.toScreen(monitor.contentRect)
            Path { path in
                for guide in preview.guides {
                    switch guide.axis {
                    case .vertical:
                        let x = local.toScreen(CGPoint(x: guide.position, y: 0)).x
                        path.move(to: CGPoint(x: x, y: screen.minY)); path.addLine(to: CGPoint(x: x, y: screen.maxY))
                    case .horizontal:
                        let y = local.toScreen(CGPoint(x: 0, y: guide.position)).y
                        path.move(to: CGPoint(x: screen.minX, y: y)); path.addLine(to: CGPoint(x: screen.maxX, y: y))
                    }
                }
            }
            .stroke(Palette.danger, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func tileHitArea(_ tile: ProfileMapLayout.WindowTile) -> some View {
        let rect = local.toScreen(tile.rect)
        return Color.clear
            .contentShape(Rectangle())
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture {
                controller.select(tile.windowID, display: tile.displayUUID)
                requestFocus()
            }
            .onHover { map.setHover(tile.id, inside: $0) }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    requestFocus()
                    controller.moveChanged(tile: tile, translation: local.toCanvas(value.translation),
                                           pointer: local.toCanvas(value.location))
                }
                .onEnded { _ in settle { controller.dragEnded() } })
            .accessibilityHidden(true)
    }

    /// Commits a drop with a spring so the tile settles into place; the drag itself has no implicit animation.
    private func settle(_ commit: () -> Void) {
        withAnimation(reduceMotion ? nil : Motion.spring, commit)
    }

    private func handles(for tile: ProfileMapLayout.WindowTile) -> some View {
        let rect = local.toScreen(controller.drag?.windowID == tile.windowID ? (controller.drag?.rect ?? tile.rect) : tile.rect)
        let limits = controller.window(tile.windowID).flatMap { SizeLimitLearning.effectiveLimits(for: $0) }
        return ForEach(ResizeHandle.allCases.filter { handle in
            // Hide a handle when every axis it moves is fixed.
            let widthFixed = limits?.fixedWidth == true, heightFixed = limits?.fixedHeight == true
            let movesX = handle.movesLeft || handle.movesRight, movesY = handle.movesTop || handle.movesBottom
            return !((movesX && widthFixed && (!movesY || heightFixed)) || (movesY && heightFixed && !movesX))
        }, id: \.self) { handle in
            let c = ResizeHandles.center(of: handle, in: rect)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Palette.accent, lineWidth: 2))
                .frame(width: ResizeHandles.handleSize, height: ResizeHandles.handleSize)
                .contentShape(Rectangle().inset(by: -3))
                .transition(.scale(scale: 0.01).combined(with: .opacity))
                .position(x: c.x, y: c.y)
                .pointerStyle(Self.pointer(for: handle))
                .help("Drag to resize the window")
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        requestFocus()
                        controller.resizeChanged(tile: tile, handle: handle, translation: local.toCanvas(value.translation))
                    }
                    .onEnded { _ in settle { controller.dragEnded() } })
                .accessibilityHidden(true)
        }
    }

    private static func pointer(for handle: ResizeHandle) -> PointerStyle {
        switch handle {
        case .topLeft: return .frameResize(position: .topLeading)
        case .top: return .frameResize(position: .top)
        case .topRight: return .frameResize(position: .topTrailing)
        case .right: return .frameResize(position: .trailing)
        case .bottomRight: return .frameResize(position: .bottomTrailing)
        case .bottom: return .frameResize(position: .bottom)
        case .bottomLeft: return .frameResize(position: .bottomLeading)
        case .left: return .frameResize(position: .leading)
        }
    }

    private func linkedGhost(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Palette.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
            .frame(width: local.toScreen(rect).width, height: local.toScreen(rect).height)
            .position(x: local.toScreen(rect).midX, y: local.toScreen(rect).midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func ghost(_ preview: BuilderDragPreview) -> some View {
        if let thumbID = preview.thumbnailSpaceID, let thumb = map.layout.thumbnails.first(where: { $0.id == thumbID }) {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Palette.accent, lineWidth: 3)
                .frame(width: local.toScreen(thumb.rect).width, height: local.toScreen(thumb.rect).height)
                .position(x: local.toScreen(thumb.rect).midX, y: local.toScreen(thumb.rect).midY)
                .allowsHitTesting(false)
        } else {
            let showsGhost = preview.kind == .move
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.accent.opacity(showsGhost ? 0.18 : 0.08))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                if let zone = preview.zoneName {
                    Text(zone).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .glassEffect(.regular, in: Capsule())
                        .padding(5)
                }
            }
            .frame(width: local.toScreen(preview.rect).width, height: local.toScreen(preview.rect).height)
            .shadow(color: Palette.accent.opacity(showsGhost ? 0.3 : 0), radius: showsGhost ? 14 : 0, y: showsGhost ? 6 : 0)
            .position(x: local.toScreen(preview.rect).midX, y: local.toScreen(preview.rect).midY)
            .animation(reduceMotion ? nil : Motion.quick, value: showsGhost)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func thumbnailHitArea(_ thumb: ProfileMapLayout.SpaceThumbnail) -> some View {
        let rect = local.toScreen(thumb.rect)
        return Color.clear
            .contentShape(Rectangle())
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture {
                if let space = map.index.space(id: thumb.id) { controller.selectSpace(space) }
                requestFocus()
            }
            .contextMenu {
                if let space = map.index.space(id: thumb.id) { spaceMenu(space) }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private func spaceMenu(_ space: ProfileSpaceIndex.Space) -> some View {
        Button("Move left") { controller.move(space, by: -1) }.disabled(!controller.canMove(space, by: -1))
            .help("Move this Desktop one place left")
        Button("Move right") { controller.move(space, by: 1) }.disabled(!controller.canMove(space, by: 1))
            .help("Move this Desktop one place right")
        Divider()
        Button(space.kind == .desktop ? "Delete Desktop…" : "Remove full-screen Space…", role: .destructive) {
            controller.delete(space)
        }
        .disabled(!controller.canDelete(space))
        .help(space.kind == .desktop ? "Delete this Desktop from the profile" : "Remove this full-screen Space from the profile")
    }

}

/// Auto layout popover (G4): previews 1-3 candidate layouts. Shown from the bar's ellipsis menu.
private struct AutoLayoutPopover: View {
    @ObservedObject var controller: BuilderCanvasController
    let monitor: ProfileMapLayout.Monitor
    @Binding var showing: Bool

    var body: some View { popover }

    private var popover: some View {
        let candidates = controller.autoLayoutCandidates(on: monitor)
        let content = monitor.contentRect
        let aspect = content.height > 0 ? content.width / content.height : 1.6
        return VStack(alignment: .leading, spacing: 10) {
            Text("Auto layout").font(.headline)
            if candidates.isEmpty {
                Text("No windows on this Desktop").foregroundStyle(.secondary)
            }
            ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                Button {
                    controller.applyAutoLayout(candidate, on: monitor)
                    showing = false
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        preview(candidate, content: content).aspectRatio(aspect, contentMode: .fit).frame(width: 150)
                        Text(candidate.name).font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .help("Apply \(candidate.name)")
                .accessibilityLabel("Apply \(candidate.name)")
            }
            Stepper("Gap \(Int(controller.autoLayoutGap)) pt", value: $controller.autoLayoutGap, in: 0...40, step: 4)
                .font(.caption)
        }
        .padding(12)
    }

    private func preview(_ candidate: AutoLayout.Candidate, content: CGRect) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
                ForEach(candidate.frames.sorted { $0.key.uuidString < $1.key.uuidString }, id: \.key) { _, r in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.accent.opacity(0.35))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Palette.accent, lineWidth: 1))
                        .frame(width: r.width / content.width * geo.size.width, height: r.height / content.height * geo.size.height)
                        .offset(x: (r.minX - content.minX) / content.width * geo.size.width,
                                y: (r.minY - content.minY) / content.height * geo.size.height)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Grid toggle with a popover for the grid size (G1, G2).
private struct GridControl: View {
    @ObservedObject var controller: BuilderCanvasController
    let monitorID: String
    @State private var showing = false

    var body: some View {
        let g = controller.grid(monitorID)
        HStack(spacing: 0) {
            Button { controller.setGrid(monitorID) { $0.isOn.toggle() } } label: {
                Label("Grid", systemImage: "grid")
            }
            .buttonStyle(ToolIconStyle(isOn: g.isOn))
            .help("Grid: show a grid on this monitor and snap dragging and resizing to it, \(g.spec.columns) x \(g.spec.rows) (\(g.isOn ? "on" : "off"))")
            .accessibilityLabel("Grid overlay")
            .accessibilityValue(g.isOn ? "on" : "off")
            Button { showing.toggle() } label: { Label("Grid size", systemImage: "chevron.down") }
                .buttonStyle(ToolIconStyle(isOn: false, width: 18))
                .help("Grid size: \(g.spec.columns) x \(g.spec.rows)")
                .accessibilityLabel("Grid size")
                .popover(isPresented: $showing, arrowEdge: .bottom) { popover }
        }
    }

    private var popover: some View {
        let g = controller.grid(monitorID)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Grid size").font(.headline)
            ForEach(GridSpec.presets, id: \.name) { preset in
                Button {
                    controller.setGrid(monitorID) { $0.spec = preset.spec; $0.isOn = true }
                } label: {
                    HStack {
                        Image(systemName: g.spec == preset.spec ? "checkmark" : "").frame(width: 14)
                        Text("\(preset.name)  \(preset.spec.columns) x \(preset.spec.rows)")
                    }
                }
                .buttonStyle(.plain)
                .help("\(preset.spec.columns) columns by \(preset.spec.rows) rows")
            }
            Divider()
            Text("Custom").font(.subheadline)
            Stepper("Columns: \(g.spec.columns)", value: Binding(get: { g.spec.columns }, set: { v in
                controller.setGrid(monitorID) { $0.spec = GridSpec(columns: v, rows: $0.spec.rows); $0.isOn = true }
            }), in: GridSpec.limits)
            Stepper("Rows: \(g.spec.rows)", value: Binding(get: { g.spec.rows }, set: { v in
                controller.setGrid(monitorID) { $0.spec = GridSpec(columns: $0.spec.columns, rows: v); $0.isOn = true }
            }), in: GridSpec.limits)
        }
        .padding(12)
        .frame(width: 210)
    }
}


// MARK: - Tools bar

/// Compact icon-only tool button: accent wash with accent icon when on, plain when off. The icon lifts on hover.
private struct ToolIconStyle: ButtonStyle {
    var isOn: Bool
    var width: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        ToolIconBody(configuration: configuration, isOn: isOn, width: width)
    }
}

private struct ToolIconBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    let width: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isOn ? Palette.accent : Color.primary)
            .offset(y: hovering ? -2 : 0)
            .animation(reduceMotion ? nil : Motion.quick, value: hovering)
            .frame(width: width, height: 28)
            .background(Capsule().fill(isOn ? Palette.accentWash : Color.clear))
            .animation(Animation.wm(reduceMotion), value: isOn)
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}

/// The edit tools for one monitor: one floating glass capsule, top centre over the map (it does not zoom or pan).
/// Monitor name on the left, icon toggles in the middle, an ellipsis menu for the actions and a plus for Add Desktop.
struct BuilderToolsBar: View {
    @ObservedObject var controller: BuilderCanvasController
    @ObservedObject private var map: ProfileMapModel
    @ObservedObject private var builder: ProfileBuilderModel
    @State private var chosenMonitorID: String?
    @State private var showsAutoLayout = false

    /// Re-reads the real windows; lives here so Edit mode has one tools row instead of two.
    var onSync: (() -> Void)?

    init(controller: BuilderCanvasController, onSync: (() -> Void)? = nil) {
        self.controller = controller
        self.onSync = onSync
        _map = ObservedObject(wrappedValue: controller.map)
        _builder = ObservedObject(wrappedValue: controller.builder)
    }

    private var monitor: ProfileMapLayout.Monitor? {
        let monitors = map.layout.monitors
        if let id = chosenMonitorID, let m = monitors.first(where: { $0.id == id }) { return m }
        if let id = map.focusedDisplayUUID, let m = monitors.first(where: { $0.id == id }) { return m }
        return monitors.first
    }

    var body: some View {
        if let monitor {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    header(monitor)
                    divider()
                    tools(monitor)
                }
                .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.xs)
                .frame(minHeight: 36)
                .glassEffect(.regular, in: Capsule())
            }
            .padding(Spacing.s)
            .onChange(of: map.focusedDisplayUUID) { _, _ in chosenMonitorID = nil }
            .sheet(isPresented: Binding(get: { controller.zoneEditorMonitor == monitor.id },
                                        set: { if !$0 { controller.zoneEditorMonitor = nil; controller.reloadLayouts() } })) {
                VStack(spacing: 0) {
                    LayoutEditorView(model: LayoutEditorModel())
                    Divider()
                    HStack { Spacer(); Button("Done") { controller.zoneEditorMonitor = nil; controller.reloadLayouts() }.keyboardShortcut(.defaultAction) }
                        .padding(8)
                }
            }
        }
    }

    @ViewBuilder private func header(_ monitor: ProfileMapLayout.Monitor) -> some View {
        let title = HStack(spacing: 4) {
            if monitor.isMain { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Tone.warning.color) }
            Text(monitor.name).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
        }
        if map.layout.monitors.count > 1 {
            Menu {
                ForEach(map.layout.monitors) { m in
                    Button { chosenMonitorID = m.id } label: {
                        if m.id == monitor.id { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                    }
                }
            } label: { title }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Monitor the tools apply to: \(monitor.name)")
            .accessibilityLabel("Monitor: \(monitor.name)")
        } else {
            title.help("Monitor: \(monitor.name)").accessibilityLabel("Monitor: \(monitor.name)")
        }
    }

    private func divider() -> some View {
        Divider().frame(height: 18).padding(.horizontal, 2)
    }

    private func state(_ on: Bool) -> String { on ? "on" : "off" }

    @ViewBuilder private func tools(_ monitor: ProfileMapLayout.Monitor) -> some View {
        let desktopCount = map.index.spaces(onDisplay: monitor.id).filter { $0.kind == .desktop }.count
        let selected = builder.selectedWindowID.flatMap { controller.window($0) }.flatMap { $0.displayUUID == monitor.id ? $0 : nil }
        HStack(spacing: 2) {
            if let window = selected {
                Button { controller.toggleFullScreen(window) } label: {
                    Label("Make full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(ToolIconStyle(isOn: window.isFullScreen))
                .help(window.isFullScreen ? "Full screen: leave full screen (on)" : "Full screen: make the selected window full screen in a new Space (off)")
                .accessibilityLabel("Make full screen")
                .accessibilityValue(state(window.isFullScreen))
                divider()
            }
            Button { controller.snapEnabled.toggle() } label: { Label("Snap", systemImage: "square.dashed.inset.filled") }
                .buttonStyle(ToolIconStyle(isOn: controller.snapEnabled))
                .help("Snap: snap to Layout zones and edges, hold Option to turn off while dragging (\(state(controller.snapEnabled)))")
                .accessibilityLabel("Snap to layout zones and edges")
                .accessibilityValue(state(controller.snapEnabled))
            GridControl(controller: controller, monitorID: monitor.id)
            Button { controller.magnetEnabled.toggle() } label: { Label("Magnet", systemImage: "arrow.left.to.line") }
                .buttonStyle(ToolIconStyle(isOn: controller.magnetEnabled))
                .help("Magnet: snap to other windows and monitor edges while dragging or resizing, Option turns off (\(state(controller.magnetEnabled)))")
                .accessibilityLabel("Magnet to window and monitor edges")
                .accessibilityValue(state(controller.magnetEnabled))
            Button { controller.linkEnabled.toggle() } label: { Label("Link", systemImage: "link") }
                .buttonStyle(ToolIconStyle(isOn: controller.linkEnabled))
                .help("Link: resizing an edge shared with a neighbour also resizes the neighbour (\(state(controller.linkEnabled)))")
                .accessibilityLabel("Linked resize")
                .accessibilityValue(state(controller.linkEnabled))
            Button { controller.allowOverlap.toggle() } label: {
                Label("Overlap", systemImage: controller.allowOverlap ? "lock.open" : "lock")
            }
            .buttonStyle(ToolIconStyle(isOn: controller.allowOverlap))
            .help(controller.allowOverlap ? "Allow overlap: tiles can be placed freely (on)"
                  : "Allow overlap: tiles cannot overlap or leave the monitor while dragging and resizing (off)")
            .accessibilityLabel("Allow overlap")
            .accessibilityValue(state(controller.allowOverlap))
            divider()
            actionsMenu(monitor)
            Button { controller.builder.addDesktop(onDisplay: monitor.id) } label: {
                Label("Add Desktop", systemImage: "plus")
            }
            .buttonStyle(ToolIconStyle(isOn: false))
            .disabled(desktopCount >= ProfileDraftEditor.maxDesktopsPerDisplay)
            .help("Add Desktop: add a Desktop to \(monitor.name)")
            .accessibilityLabel("Add Desktop")
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit tools for \(monitor.name)")
    }

    /// Ellipsis menu with the text-labelled actions: Sync, Layout zones, Auto layout.
    private func actionsMenu(_ monitor: ProfileMapLayout.Monitor) -> some View {
        Menu {
            if let onSync {
                Button(action: onSync) { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                    .help("Sync: read your real windows now and update the map")
            }
            layoutMenu(monitor)
            Button { showsAutoLayout = true } label: { Label("Auto layout", systemImage: "wand.and.stars") }
                .help("Auto layout: arrange this Desktop's windows on \(monitor.name) by how many there are")
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More: Sync, Layout, Auto layout")
        .accessibilityLabel("More edit actions")
        .popover(isPresented: $showsAutoLayout, arrowEdge: .bottom) {
            AutoLayoutPopover(controller: controller, monitor: monitor, showing: $showsAutoLayout)
        }
    }

    @ViewBuilder fileprivate func layoutMenu(_ monitor: ProfileMapLayout.Monitor) -> some View {
        let matching = controller.layoutsMatching(monitor.id)
        let active = controller.activeLayout(monitor.id)
        Menu {
            Button { controller.chooseLayout(nil, on: monitor.id) } label: {
                if active == nil { Label("No layout", systemImage: "checkmark") } else { Text("No layout") }
            }
            .help("Stop snapping to layout zones on this monitor")
            ForEach(matching) { layout in
                Button { controller.chooseLayout(layout.id, on: monitor.id) } label: {
                    if active?.id == layout.id { Label(layout.name, systemImage: "checkmark") } else { Text(layout.name) }
                }
                .help("Snap to the \(layout.name) zones on this monitor")
            }
            if matching.isEmpty { Text("No saved Layouts for this monitor") }
            Divider()
            Button("Edit zones…") { controller.zoneEditorMonitor = monitor.id }
            Button("Save current arrangement as zones…") {
                let name = "\(monitor.name) \(matching.count + 1)"
                controller.saveArrangementAsZones(on: monitor, name: name)
            }
            if !matching.isEmpty {
                Menu("Apply zones") {
                    ForEach(matching) { layout in
                        Button(layout.name) { controller.applyZones(layout, on: monitor) }
                    }
                }
            }
        } label: {
            Label("Layout", systemImage: "square.grid.2x2")
        }
        .help("Layout: zones to snap to on this monitor (\(active?.name ?? "none"))")
    }
}

// MARK: - Host

/// `ProfileMapCanvas` in Edit mode: the same map with the builder overlay and key handling plugged in.
struct BuilderMapCanvas: View {
    @ObservedObject var map: ProfileMapModel
    @StateObject private var controller: BuilderCanvasController
    private let builder: ProfileBuilderModel
    @State private var toolsShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(map: ProfileMapModel, builder: ProfileBuilderModel) {
        self.map = map
        self.builder = builder
        _controller = StateObject(wrappedValue: BuilderCanvasController(map: map, builder: builder))
    }

    var body: some View {
        ProfileMapCanvas(model: map,
                         canvasOverlay: AnyView(BuilderCanvasOverlay(controller: controller)),
                         keyOverride: { controller.handleKey($0) })
            .overlay(alignment: .top) {
                ZStack {
                    // Drops in from the top when Edit mode opens (and leaves the same way if the host animates its removal).
                    if toolsShown {
                        BuilderToolsBar(controller: controller, onSync: { Task { await builder.syncNow() } })
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : Motion.spring, value: toolsShown)
            }
            .onAppear { toolsShown = true }
            .onDisappear { toolsShown = false }
    }
}
