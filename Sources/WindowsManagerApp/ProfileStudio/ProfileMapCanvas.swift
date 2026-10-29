import SwiftUI
import WMCore

/// Loads one profile into a `ProfileMapModel` and shows the read-only map with its zoom bar, tray and legend.
/// `status` is optional: nil hides every status badge (UI3 supplies it for "Compare with now").
struct ProfileMapHost: View {
    let row: ProfileStudioRow
    var status: ProfileLiveStatus?
    @StateObject private var model = ProfileMapModel()

    var body: some View {
        VStack(spacing: 0) {
            ProfileMapCanvas(model: model)
            Divider()
            MapLegendView(showsStatus: model.status != nil, showsStageStrip: model.usesStageManager)
        }
        .task(id: row) { reloadProfile() }
        .onChange(of: status) { _, newValue in model.status = newValue }
        .onAppear { model.status = status }
    }

    private func reloadProfile() {
        model.load(try? AppState.current?.store.load(row.id))
    }
}

private struct CanvasFocusRequestKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Gives the map canvas keyboard focus (the Edit mode overlay calls it when a tile is clicked).
    var canvasFocusRequest: () -> Void {
        get { self[CanvasFocusRequestKey.self] }
        set { self[CanvasFocusRequestKey.self] = newValue }
    }
}

private struct CanvasFitRequestKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Fits the whole map in the window (the Edit mode overlay calls it on a double-click of empty canvas).
    var canvasFitRequest: () -> Void {
        get { self[CanvasFitRequestKey.self] }
        set { self[CanvasFitRequestKey.self] = newValue }
    }
}

/// The map: monitors drawn to scale, a Space strip per monitor, window tiles, the tray and the zoom bar.
struct ProfileMapCanvas: View {
    @ObservedObject var model: ProfileMapModel
    /// Edit mode (UI5): drawn on top of the monitors, in canvas coordinates. Nil in View mode.
    /// The Sync button at the top of the canvas: re-reads the real windows now. Nil hides the button.
    var onSync: (() -> Void)?
    var canvasOverlay: AnyView?
    /// Edit mode (UI5): sees every handled key first; returns true when it used the key. Nil in View mode.
    var keyOverride: ((KeyPress) -> Bool)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    init(model: ProfileMapModel, onSync: (() -> Void)? = nil, canvasOverlay: AnyView? = nil, keyOverride: ((KeyPress) -> Bool)? = nil) {
        self.onSync = onSync
        self.model = model
        self.canvasOverlay = canvasOverlay
        self.keyOverride = keyOverride
        // Stacks collapse in View mode and Compare; Edit mode (it supplies a key override) keeps every tile.
        model.collapsesStacks = keyOverride == nil
    }

    private var displayLayout: ProfileMapLayout { model.displayLayout }
    private var metrics: MapMetrics { MapMetrics(zoom: CGFloat(model.zoom)) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    CanvasGridBackground(zoom: model.zoom, offset: model.offset)
                    // Laid out at the zoomed size (no scaleEffect), so text and strokes render at native resolution.
                    canvasContent
                        .frame(width: displayLayout.canvasSize.width, height: displayLayout.canvasSize.height,
                               alignment: .topLeading)
                        .environment(\.layoutDirection, .leftToRight)   // physical geometry, never mirrored
                        .allowsHitTesting(!model.panModeActive)
                        .offset(x: model.offset.x, y: model.offset.y)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .background(CanvasNavigator(model: model))
                .onAppear { model.setViewport(geo.size) }
                .onChange(of: geo.size) { _, size in model.setViewport(size) }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            if !model.index.tray.isEmpty {
                Divider()
                trayRow
            }
        }
        .focusable()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .tab, .delete, .deleteForward, .escape, .return,
                           "1", "2", "3", "4", "5", "6", "7", "8", "9"]) { press in
            if keyOverride?(press) == true { return .handled }
            switch press.key {
            case .escape: return model.collapseFan() ? .handled : .ignored
            case .return: return model.fanOutSelected() ? .handled : .ignored
            case .delete, .deleteForward, "1", "2", "3", "4", "5", "6", "7", "8", "9": return .ignored
            case .leftArrow: model.moveSelection(.left)
            case .rightArrow: model.moveSelection(.right)
            case .upArrow: model.moveSelection(.up)
            case .downArrow: model.moveSelection(.down)
            default: model.stepSpace(forward: !press.modifiers.contains(.shift))
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map of \(model.profile?.name ?? "profile")")
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            if let onSync {
                Button(action: onSync) { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Read your real windows now and update the map")
                    .accessibilityLabel("Sync with real windows")
            }
            if keyOverride != nil {
                Text("Drag a tile to move it, its handles to resize. Lock = fixed-size window.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help("Edit mode: drag tiles to move, drag handles to resize. A lock badge on a tile means the app does not allow resizing.")
            }
            if let summary = model.summaryText {
                Image(systemName: "checklist").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(summaryWithParked(summary)).font(.callout).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if keyOverride == nil {
                // View mode only: previous / next Space on the shown monitor.
                Button { stepShownDesktop(forward: false) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityLabel("Previous Desktop").help("Previous Desktop (Cmd+[)")
                Button { stepShownDesktop(forward: true) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut("]", modifiers: .command)
                    .accessibilityLabel("Next Desktop").help("Next Desktop (Cmd+])")
            }
            Button { model.zoomBy(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .accessibilityLabel("Zoom out").help("Zoom out (Cmd+-)")
            Slider(value: Binding(get: { model.zoom }, set: { model.setZoom($0) }),
                   in: CanvasViewport.zoomRange)
                .frame(width: 100)
                .accessibilityLabel("Zoom")
                .accessibilityValue("\(Int((model.zoom * 100).rounded())) percent")
                .help("Hold Space and drag to pan, pinch or Cmd+scroll to zoom")
            Button { model.zoomBy(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel("Zoom in").help("Zoom in (Cmd+=)")
            Button { model.actualSize() } label: {
                Text("\(Int((model.zoom * 100).rounded()))%")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .accessibilityLabel("Reset zoom to 100 percent").help("Reset zoom to 100% (Cmd+0)")
            Button("Fit") { model.fit() }
                .help("Fit the map to the window (Cmd+1)")
            Button { model.zoomToSelection() } label: { Image(systemName: "scope") }
                .keyboardShortcut("2", modifiers: .command)
                .accessibilityLabel("Zoom to selection").help("Zoom to the selected window or Space (Cmd+2)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    /// The model's summary does not count parked windows, so the canvas adds them when Compare data is present.
    private func summaryWithParked(_ summary: String) -> String {
        guard let parked = model.status?.summary.mayBeParked, parked > 0 else { return summary }
        return summary + ", \(parked) may be parked"
    }

    /// Cmd+[ / Cmd+]: the previous or next Space on the shown monitor (the focused one, else the first).
    private func stepShownDesktop(forward: Bool) {
        guard let uuid = model.focusedDisplayUUID ?? model.layout.monitors.first?.id else { return }
        let spaces = model.index.spaces(onDisplay: uuid)
        guard spaces.count > 1 else { return }
        let current = model.shownSpace(onDisplay: uuid).flatMap { shown in spaces.firstIndex { $0.id == shown.id } } ?? 0
        let next = (current + (forward ? 1 : -1) + spaces.count) % spaces.count
        model.selectSpace(spaces[next].id)
    }

    // MARK: Canvas

    @ViewBuilder private var canvasContent: some View {
        let layout = displayLayout
        if layout.monitors.isEmpty {
            noDisplays
        } else {
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { model.selectWindow(nil) }
                    .onTapGesture(count: 2) { model.fit() }
                ForEach(layout.monitors) { monitor in
                    monitorView(monitor)
                }
                if let canvasOverlay {
                    canvasOverlay
                        .environment(\.canvasFocusRequest, { focused = true })
                        .environment(\.canvasFitRequest, { model.fit() })
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.spaceSelection)
        }
    }

    private func monitorView(_ monitor: ProfileMapLayout.Monitor) -> some View {
        let layout = displayLayout
        let windowsByID = Dictionary((model.profile?.windows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let thumbs = layout.thumbnails.filter { $0.displayUUID == monitor.id }
        let shown = model.shownSpace(onDisplay: monitor.id)
        let tiles = layout.windows.filter { $0.displayUUID == monitor.id }
        let focusedHere = model.focusedDisplayUUID == monitor.id && layout.monitors.count > 1
        let spaceCount = thumbs.count
        let shownLabel = shown.map { model.spaceName($0) }
        // Stage Manager (P6.58): every monitor of such a profile has a lane on its left edge.
        let stageLane = model.usesStageManager ? ProfileMapModel.stageLaneRect(for: monitor) : nil

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focusedHere ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: 1.5))
                .frame(width: monitor.frame.width, height: monitor.frame.height)
                .offset(x: monitor.frame.minX, y: monitor.frame.minY)
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
                .frame(width: monitor.contentRect.width, height: monitor.contentRect.height)
                .offset(x: monitor.contentRect.minX, y: monitor.contentRect.minY)
            monitorTitle(monitor, shownLabel: shownLabel, showsStageBadge: stageLane != nil)
                .offset(x: monitor.frame.minX + 6, y: monitor.frame.minY + 4)

            // Back to front: the layout lists windows back to front already; sort again to be safe.
            // A collapsed stack draws only its front window, with card edges and a badge.
            let hidden = model.hiddenTileIDs
            ForEach(tiles.filter { !hidden.contains($0.id) }.sorted { $0.zIndex > $1.zIndex }) { tile in
                if let window = windowsByID[tile.windowID] {
                    tileView(window, tile: tile, monitor: monitor, shown: shown, among: tiles)
                        .offset(x: tile.rect.minX, y: tile.rect.minY)
                }
            }
            if model.collapsesStacks, let id = model.fannedStackID, let stack = model.stack(withID: id),
               let front = layout.windows.first(where: { $0.windowID == model.frontWindowID(of: stack) && $0.spaceID == stack.spaceID }),
               front.displayUUID == monitor.id {
                StackFanView(stack: stack,
                             windows: model.orderedMembers(of: stack).compactMap { windowsByID[$0] },
                             selectedID: model.selectedWindowID, anchor: front.rect, bounds: monitor.frame,
                             metrics: metrics, onSelect: { model.selectWindow($0); focused = true })
            }
            if tiles.isEmpty {
                Text("No windows on this display")
                    .font(.system(size: metrics.font(11))).foregroundStyle(.secondary)
                    .frame(width: monitor.contentRect.width, height: monitor.contentRect.height)
                    .offset(x: monitor.contentRect.minX, y: monitor.contentRect.minY)
            } else if let shown, shown.windowIDs.isEmpty {
                Text("No windows on this Space")
                    .font(.system(size: metrics.font(11))).foregroundStyle(.secondary)
                    .frame(width: monitor.contentRect.width, height: monitor.contentRect.height)
                    .offset(x: monitor.contentRect.minX, y: monitor.contentRect.minY)
            }
            if let stageLane {
                StageStripLaneView(groups: model.stageGroups(onDisplay: monitor.id),
                                   selectedWindowID: model.selectedWindowID, metrics: metrics,
                                   onSelect: { model.selectWindow($0); focused = true })
                    .frame(width: stageLane.width, height: stageLane.height)
                    .offset(x: stageLane.minX, y: stageLane.minY)
            }
            SpaceStripView(thumbnails: thumbs, index: model.index, windows: windowsByID,
                           spaceStatus: model.status?.spaces ?? [:],
                           spaceName: { model.spaceName($0) },
                           onSelect: { model.selectSpace($0); focused = true }, metrics: metrics)
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(monitor.name)\(monitor.isMain ? ", main" : ""), showing \(shownLabel ?? "no Space")"
            + (spaceCount > 0 ? " of \(spaceCount) Spaces" : "") + (stageLane != nil ? ", Stage Manager" : ""))
    }

    /// One window tile; the visible front of a stack also gets its card edges, badge and stack gestures.
    @ViewBuilder private func tileView(_ window: WindowSnapshot, tile: ProfileMapLayout.WindowTile,
                                       monitor: ProfileMapLayout.Monitor, shown: ProfileSpaceIndex.Space?,
                                       among tiles: [ProfileMapLayout.WindowTile]) -> some View {
        let stack = model.stackShown(by: tile)
        let collapsed = stack != nil && model.collapsesStacks
        let select: () -> Void = {
            if let stack, collapsed {
                // Option-click cycles the front window; a plain click selects the stack and fans it out.
                if NSEvent.modifierFlags.contains(.option) { model.cycleFront(stack) } else { model.fanOut(stack) }
            } else {
                model.selectWindow(tile.windowID)
            }
            focused = true
        }
        let content = WindowTileView(window: window, tile: tile,
                                     status: model.status?.windows[tile.windowID],
                                     isSelected: model.selectedWindowID == tile.windowID,
                                     isHovered: model.hoveredTileID == tile.id,
                                     metrics: metrics,
                                     stackCount: stack?.count ?? 1,
                                     locationText: location(of: tile, monitor: monitor, shown: shown, among: tiles),
                                     onSelect: select,
                                     onHover: { inside in model.setHover(tile.id, inside: inside) })
        // Edit mode keeps every tile; a window behind a stack's top tile draws only an outline (no overlapping labels).
        let stackedBehind = stack == nil && !model.collapsesStacks && model.stack(containing: tile.windowID, spaceID: tile.spaceID) != nil
        if stackedBehind {
            StackedBehindTile(size: tile.rect.size, tint: AppTint.color(for: window.app))
        } else if let stack {
            TileStackView(size: tile.rect.size, tint: AppTint.color(for: window.app), showsEdges: collapsed) { content }
                .overlay(alignment: .bottomTrailing) {
                    StackBadge(stack: stack, appName: window.app.name, metrics: metrics, isInteractive: collapsed,
                               onCycle: { model.cycleFront(stack); focused = true })
                }
                .accessibilityAction(named: "Next window in stack") { if collapsed { model.cycleFront(stack) } }
        } else {
            content
        }
    }

    private func monitorTitle(_ monitor: ProfileMapLayout.Monitor, shownLabel: String?, showsStageBadge: Bool) -> some View {
        HStack(spacing: 4) {
            if monitor.isMain { Image(systemName: "star.fill").font(.system(size: metrics.font(9))) }
            (Text(monitor.name).fontWeight(.semibold)
                + Text(shownLabel.map { " · " + $0 } ?? "").foregroundColor(.secondary))
                .font(.system(size: metrics.font(11)))
                .lineLimit(1).truncationMode(.tail)
                .accessibilityHidden(true)
            if showsStageBadge {
                let badge = "Stage Manager was on when captured. Strip windows sit in the lane on the left."
                Text("Stage Manager")
                    .font(.system(size: metrics.font(9), weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color(nsColor: .separatorColor).opacity(0.35), in: Capsule())
                    .help(badge)
                    .accessibilityLabel(badge)
            }
        }
        .padding(.horizontal, 4)
        .frame(width: max(monitor.frame.width - 12, 20), height: max(ProfileMapLayout.headerHeight * CGFloat(model.zoom) - 4, 10), alignment: .leading)
    }

    private func location(of tile: ProfileMapLayout.WindowTile, monitor: ProfileMapLayout.Monitor,
                          shown: ProfileSpaceIndex.Space?, among tiles: [ProfileMapLayout.WindowTile]) -> String {
        let ranked = tiles.sorted { $0.zIndex < $1.zIndex }
        let rank = (ranked.firstIndex { $0.id == tile.id } ?? 0) + 1
        let spaceText = shown.map { model.spaceName($0) } ?? "Space"
        return "\(spaceText) of \(monitor.name), \(rank) of \(ranked.count)"
    }

    private var noDisplays: some View {
        VStack(spacing: 8) {
            Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No displays found").font(.headline).foregroundStyle(.secondary)
            ForEach(model.index.spaces) { space in
                Text("\(model.spaceName(space)): \(space.windowIDs.count) window\(space.windowIDs.count == 1 ? "" : "s")")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: Tray

    private var trayRow: some View {
        let windows = Dictionary((model.profile?.windows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func chips(_ reason: ProfileSpaceIndex.TrayReason) -> [ProfileSpaceIndex.TrayEntry] {
            model.index.tray.filter { $0.reason == reason }
        }
        return ScrollView(.horizontal) {
            HStack(spacing: 14) {
                trayGroup("Minimized", symbol: "arrow.down.right.and.arrow.up.left", entries: chips(.minimized), windows: windows)
                trayGroup("On all Desktops", symbol: "rectangle.dashed", entries: chips(.onAllDesktops), windows: windows)
                trayGroup("No place on a Space", symbol: "questionmark.square.dashed", entries: chips(.unplaced), windows: windows)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Windows without a place on the map")
    }

    @ViewBuilder private func trayGroup(_ title: String, symbol: String, entries: [ProfileSpaceIndex.TrayEntry],
                                        windows: [UUID: WindowSnapshot]) -> some View {
        if !entries.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(title + ":").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(entries, id: \.windowID) { entry in
                    if let window = windows[entry.windowID] {
                        let selected = model.selectedWindowID == window.id
                        Button { model.selectWindow(window.id) } label: {
                            HStack(spacing: 4) {
                                Image(nsImage: AppIconCache.icon(for: window.app)).resizable().frame(width: 14, height: 14)
                                Text(trayText(window)).font(.system(size: 11)).lineLimit(1)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppTint.color(for: window.app).opacity(0.18), in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help("Select \(trayText(window)) on the map")
                        .accessibilityLabel("\(trayText(window)), \(title.lowercased())")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func trayText(_ window: WindowSnapshot) -> String {
        if let title = window.title, !title.isEmpty { return "\(window.app.name) \"\(title)\"" }
        return window.app.name
    }
}
