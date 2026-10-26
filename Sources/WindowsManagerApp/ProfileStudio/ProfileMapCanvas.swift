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
            MapLegendView(showsStatus: model.status != nil)
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

/// The map: monitors drawn to scale, a Space strip per monitor, window tiles, the tray and the zoom bar.
struct ProfileMapCanvas: View {
    @ObservedObject var model: ProfileMapModel
    /// Edit mode (UI5): drawn on top of the monitors, in canvas coordinates. Nil in View mode.
    var canvasOverlay: AnyView?
    /// Edit mode (UI5): sees every handled key first; returns true when it used the key. Nil in View mode.
    var keyOverride: ((KeyPress) -> Bool)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    canvasContent
                        .frame(width: model.layout.canvasSize.width, height: model.layout.canvasSize.height,
                               alignment: .topLeading)
                        .environment(\.layoutDirection, .leftToRight)   // physical geometry, never mirrored
                }
                .onAppear { model.setViewport(geo.size) }
                .onChange(of: geo.size) { _, size in model.setViewport(size) }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .gesture(MagnifyGesture()
                .onChanged { model.pinchChanged($0.magnification) }
                .onEnded { _ in model.pinchEnded() })
            if !model.index.tray.isEmpty {
                Divider()
                trayRow
            }
        }
        .focusable()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .tab, .delete, .deleteForward, .escape,
                           "1", "2", "3", "4", "5", "6", "7", "8", "9"]) { press in
            if keyOverride?(press) == true { return .handled }
            switch press.key {
            case .delete, .deleteForward, .escape, "1", "2", "3", "4", "5", "6", "7", "8", "9": return .ignored
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
            if let summary = model.summaryText {
                Image(systemName: "checklist").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(summaryWithParked(summary)).font(.callout)
            }
            Spacer()
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
                .keyboardShortcut("-", modifiers: .command)
                .accessibilityLabel("Zoom out").help("Zoom out (Cmd+-)")
            Slider(value: Binding(get: { model.zoom }, set: { model.setZoom($0) }),
                   in: ProfileMapLayout.zoomRange)
                .frame(width: 140)
                .accessibilityLabel("Zoom")
                .accessibilityValue("\(Int((model.zoom * 100).rounded())) percent")
            Button { model.zoomBy(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .accessibilityLabel("Zoom in").help("Zoom in (Cmd+=)")
            Text("\(Int((model.zoom * 100).rounded()))%")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing).accessibilityHidden(true)
            Button("Fit") { model.setZoom(1) }
                .keyboardShortcut("0", modifiers: .command)
                .help("Fit the map to the window (Cmd+0)")
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
        let layout = model.layout
        if layout.monitors.isEmpty {
            noDisplays
        } else {
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { model.selectWindow(nil) }
                ForEach(layout.monitors) { monitor in
                    monitorView(monitor)
                }
                if let canvasOverlay {
                    canvasOverlay.environment(\.canvasFocusRequest, { focused = true })
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.zoom)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.spaceSelection)
        }
    }

    private func monitorView(_ monitor: ProfileMapLayout.Monitor) -> some View {
        let layout = model.layout
        let windowsByID = Dictionary(uniqueKeysWithValues: (model.profile?.windows ?? []).map { ($0.id, $0) })
        let thumbs = layout.thumbnails.filter { $0.displayUUID == monitor.id }
        let shown = model.shownSpace(onDisplay: monitor.id)
        let tiles = layout.windows.filter { $0.displayUUID == monitor.id }
        let focusedHere = model.focusedDisplayUUID == monitor.id && layout.monitors.count > 1
        let spaceCount = thumbs.count
        let shownLabel = shown.map { model.spaceName($0) }

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
            monitorTitle(monitor, shownLabel: shownLabel)
                .offset(x: monitor.frame.minX + 6, y: monitor.frame.minY + 4)

            // Back to front: the layout lists windows back to front already; sort again to be safe.
            ForEach(tiles.sorted { $0.zIndex > $1.zIndex }) { tile in
                if let window = windowsByID[tile.windowID] {
                    WindowTileView(window: window, tile: tile,
                                   status: model.status?.windows[tile.windowID],
                                   isSelected: model.selectedWindowID == tile.windowID,
                                   isHovered: model.hoveredTileID == tile.id,
                                   locationText: location(of: tile, monitor: monitor, shown: shown, among: tiles),
                                   onSelect: { model.selectWindow(tile.windowID); focused = true },
                                   onHover: { inside in
                                       model.setHover(tile.id, inside: inside)
                                   })
                        .offset(x: tile.rect.minX, y: tile.rect.minY)
                }
            }
            if let shown, shown.windowIDs.isEmpty {
                Text("No windows on this Space")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: monitor.contentRect.width, height: monitor.contentRect.height)
                    .offset(x: monitor.contentRect.minX, y: monitor.contentRect.minY)
            }
            SpaceStripView(thumbnails: thumbs, index: model.index, windows: windowsByID,
                           spaceStatus: model.status?.spaces ?? [:],
                           spaceName: { model.spaceName($0) },
                           onSelect: { model.selectSpace($0); focused = true })
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(monitor.name)\(monitor.isMain ? ", main" : ""), showing \(shownLabel ?? "no Space")"
            + (spaceCount > 0 ? " of \(spaceCount) Spaces" : ""))
    }

    private func monitorTitle(_ monitor: ProfileMapLayout.Monitor, shownLabel: String?) -> some View {
        HStack(spacing: 4) {
            if monitor.isMain { Image(systemName: "star.fill").font(.system(size: 10)) }
            Text(monitor.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            if let shownLabel {
                Text("· " + shownLabel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: max(monitor.frame.width - 12, 20), alignment: .leading)
        .accessibilityHidden(true)
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
        let windows = Dictionary(uniqueKeysWithValues: (model.profile?.windows ?? []).map { ($0.id, $0) })
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
