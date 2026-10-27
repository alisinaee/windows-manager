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
}

@MainActor
final class BuilderCanvasController: ObservableObject {
    let map: ProfileMapModel
    let builder: ProfileBuilderModel

    @Published var snapEnabled = true
    @Published private(set) var layouts: [WMCore.Layout] = []
    @Published private(set) var chosenLayout: [String: UUID] = [:]
    @Published private(set) var drag: BuilderDragPreview?
    @Published var isDropTargeted = false

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
        preview.rect = result.rect
        preview.zoneName = result.zoneName
        preview.displayUUID = target.id
        drag = preview
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
        var rect = ResizeHandles.resize(preview.startRect, handle: handle, by: translation, minSize: minSize,
                                        within: monitor.contentRect)
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
            builder.resizeWindow(id, to: MapSnapping.relativeFrame(of: preview.rect, in: monitor.contentRect), zoneName: nil)
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
            ForEach(layout.windows.sorted { $0.zIndex > $1.zIndex }) { tile in tileHitArea(tile) }
            if let tile = selectedTile { handles(for: tile) }
            if let preview = controller.drag { ghost(preview) }
            ForEach(layout.thumbnails) { thumb in thumbnailHitArea(thumb) }
            ForEach(layout.monitors) { monitor in monitorControls(monitor) }
        }
        .frame(width: local.toScreen(layout.canvasSize).width, height: local.toScreen(layout.canvasSize).height,
               alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }

    // MARK: Layers

    private var background: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                controller.select(nil)
                requestFocus()
            }
            .onTapGesture(count: 2) { requestFit() }
            .dropDestination(for: LibraryDragPayload.self) { items, location in
                controller.handleDrop(items, at: local.toCanvas(location))
            } isTargeted: { controller.isDropTargeted = $0 }
            .overlay {
                if controller.isDropTargeted {
                    ForEach(map.layout.monitors) { monitor in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
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
                    .fill(Color.accentColor.opacity(active ? 0.25 : 0.06))
                    .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(active ? 0.9 : 0.4),
                                                      style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
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
                .onEnded { _ in controller.dragEnded() })
            .accessibilityHidden(true)
    }

    private func handles(for tile: ProfileMapLayout.WindowTile) -> some View {
        let rect = local.toScreen(controller.drag?.windowID == tile.windowID ? (controller.drag?.rect ?? tile.rect) : tile.rect)
        return ForEach(ResizeHandle.allCases, id: \.self) { handle in
            let c = ResizeHandles.center(of: handle, in: rect)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 1.5))
                .frame(width: ResizeHandles.handleSize, height: ResizeHandles.handleSize)
                .contentShape(Rectangle().inset(by: -3))
                .position(x: c.x, y: c.y)
                .pointerStyle(Self.pointer(for: handle))
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        requestFocus()
                        controller.resizeChanged(tile: tile, handle: handle, translation: local.toCanvas(value.translation))
                    }
                    .onEnded { _ in controller.dragEnded() })
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

    @ViewBuilder private func ghost(_ preview: BuilderDragPreview) -> some View {
        if let thumbID = preview.thumbnailSpaceID, let thumb = map.layout.thumbnails.first(where: { $0.id == thumbID }) {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .frame(width: local.toScreen(thumb.rect).width, height: local.toScreen(thumb.rect).height)
                .position(x: local.toScreen(thumb.rect).midX, y: local.toScreen(thumb.rect).midY)
                .allowsHitTesting(false)
        } else {
            let showsGhost = preview.kind == .move
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(showsGhost ? 0.18 : 0.08))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                if let zone = preview.zoneName {
                    Text(zone).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.regularMaterial, in: Capsule())
                        .padding(5)
                }
            }
            .frame(width: local.toScreen(preview.rect).width, height: local.toScreen(preview.rect).height)
            .position(x: local.toScreen(preview.rect).midX, y: local.toScreen(preview.rect).midY)
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
        Button("Move right") { controller.move(space, by: 1) }.disabled(!controller.canMove(space, by: 1))
        Divider()
        Button(space.kind == .desktop ? "Delete Desktop…" : "Remove full-screen Space…", role: .destructive) {
            controller.delete(space)
        }.disabled(!controller.canDelete(space))
    }

    // MARK: Desktop strip controls

    private func monitorControls(_ monitor: ProfileMapLayout.Monitor) -> some View {
        let desktopCount = map.index.spaces(onDisplay: monitor.id).filter { $0.kind == .desktop }.count
        let selected = builder.selectedWindowID.flatMap { controller.window($0) }.flatMap { $0.displayUUID == monitor.id ? $0 : nil }
        return HStack(spacing: 6) {
            if let window = selected {
                Toggle(isOn: Binding(get: { window.isFullScreen }, set: { _ in controller.toggleFullScreen(window) })) {
                    Label("Make full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .toggleStyle(.button).labelStyle(.iconOnly)
                .help(window.isFullScreen ? "Leave full screen" : "Make the selected window full screen in a new Space")
            }
            layoutMenu(monitor)
            Toggle(isOn: $controller.snapEnabled) { Label("Snap", systemImage: "magnet") }
                .toggleStyle(.button).labelStyle(.iconOnly)
                .help("Snap to Layout zones and edges (hold Option to turn off while dragging)")
            Button { controller.builder.addDesktop(onDisplay: monitor.id) } label: { Label("Add Desktop", systemImage: "plus") }
                .labelStyle(.iconOnly)
                .disabled(desktopCount >= ProfileDraftEditor.maxDesktopsPerDisplay)
                .help("Add a Desktop to \(monitor.name)")
        }
        .controlSize(.small)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
        .position(x: local.toScreen(monitor.frame).maxX - 8, y: local.toScreen(monitor.frame).minY + 14)
        .alignmentGuide(.leading) { $0[.leading] }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit controls for \(monitor.name)")
    }

    private func layoutMenu(_ monitor: ProfileMapLayout.Monitor) -> some View {
        let matching = controller.layoutsMatching(monitor.id)
        let active = controller.activeLayout(monitor.id)
        return Menu {
            Button { controller.chooseLayout(nil, on: monitor.id) } label: {
                if active == nil { Label("No layout", systemImage: "checkmark") } else { Text("No layout") }
            }
            ForEach(matching) { layout in
                Button { controller.chooseLayout(layout.id, on: monitor.id) } label: {
                    if active?.id == layout.id { Label(layout.name, systemImage: "checkmark") } else { Text(layout.name) }
                }
            }
            if matching.isEmpty { Text("No saved Layouts for this monitor") }
        } label: {
            Label("Layout zones", systemImage: "square.grid.2x2")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Layout zones to snap to: \(active?.name ?? "none")")
    }
}

// MARK: - Host

/// `ProfileMapCanvas` in Edit mode: the same map with the builder overlay and key handling plugged in.
struct BuilderMapCanvas: View {
    @ObservedObject var map: ProfileMapModel
    @StateObject private var controller: BuilderCanvasController

    init(map: ProfileMapModel, builder: ProfileBuilderModel) {
        self.map = map
        _controller = StateObject(wrappedValue: BuilderCanvasController(map: map, builder: builder))
    }

    var body: some View {
        ProfileMapCanvas(model: map,
                         canvasOverlay: AnyView(BuilderCanvasOverlay(controller: controller)),
                         keyOverride: { controller.handleKey($0) })
    }
}
