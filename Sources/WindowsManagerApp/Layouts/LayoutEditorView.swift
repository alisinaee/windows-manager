import AppKit
import SwiftUI
import WMCore

/// Layout editor: layouts on the left, the monitor mini map and grid controls in the middle, running apps on the right.
/// Drag an app chip onto a zone to assign it; drag a zone edge to resize; tap a preset to start over.
/// Tap a zone to select it; Shift- or Command-click adds or removes zones from the selection for merging.
struct LayoutEditorView: View {
    @ObservedObject var model: LayoutEditorModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let deleted = model.deletedLayout {
                Banner(
                    tone: .neutral,
                    title: "Deleted \(deleted.layout.name)",
                    actionLabel: "Undo",
                    action: { model.undoDelete() },
                    onDismiss: { model.dismissDeletedLayout() })
                    .padding(.horizontal, Spacing.m)
                    .padding(.top, Spacing.m)
            }
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 180)
                Divider()
                editor
                    .frame(minWidth: 420, maxWidth: .infinity)
                Divider()
                appsList
                    .frame(width: 190)
            }
        }
        .frame(minWidth: 840, minHeight: 480)
        .confirmationDialog(
            "Delete \(model.selected?.name ?? "this layout")?",
            isPresented: $model.confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Layout", role: .destructive) { model.deleteSelected() }
        } message: {
            Text("You can undo this for a few seconds after deleting.")
        }
    }

    // MARK: Layout list

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Layouts").font(.headline)
            if model.layouts.isEmpty {
                ContentUnavailableView {
                    Label("No layouts", systemImage: "rectangle.split.2x2")
                } description: {
                    Text("Create one from a preset.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { model.selectedID = $0 })) {
                    ForEach(model.layouts) { layout in
                        Text(layout.name).tag(layout.id as UUID?)
                    }
                }
            }
            Menu("New from preset") {
                ForEach(LayoutPreset.allCases) { preset in
                    Button(preset.title) { model.addLayout(preset) }
                }
            }
            Button("Delete layout", role: .destructive) { model.confirmingDelete = true }
                .disabled(model.selected == nil)
        }
        .padding(12)
    }

    // MARK: Mini map

    @ViewBuilder private var editor: some View {
        if let layout = model.selected, let display = model.selectedDisplay {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Name", text: $model.nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { model.commitName() }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { model.commitName() }
                        }
                    Picker("Display", selection: Binding(get: { layout.displayKey ?? "" }, set: { model.setDisplay($0.isEmpty ? nil : $0) })) {
                        Text("Any display").tag("")
                        ForEach(model.displays, id: \.uuid) { d in
                            Text(d.name).tag(d.uuid.uppercased())
                        }
                    }
                    .frame(maxWidth: 220)
                }
                HStack(spacing: 6) {
                    Text("Presets").foregroundStyle(.secondary)
                    ForEach(LayoutPreset.allCases) { preset in
                        Button(preset.title) { model.applyPreset(preset) }
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    MiniMap(model: model, layout: layout, display: display)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    LayoutGridControls(model: model.gridControls)
                        .frame(width: 180)
                }
                .frame(maxHeight: .infinity)
                HStack {
                    Button("Split left | right") { model.splitSelectedZone(.vertical) }
                    Button("Split top / bottom") { model.splitSelectedZone(.horizontal) }
                    Button("Delete zone") { model.deleteSelectedZone() }
                    Spacer()
                    Text(selectionHint)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .disabled(model.selectedZoneID == nil)
                if let error = model.errorText {
                    Banner(tone: .danger, title: "Something went wrong", message: error, onDismiss: { model.dismissError() })
                }
            }
            .padding(12)
        } else if model.layouts.isEmpty {
            ContentUnavailableView {
                Label("No layouts yet", systemImage: "rectangle.split.2x2")
            } description: {
                if model.displays.isEmpty {
                    Text("No displays found. Create a layout from a preset to start.")
                } else {
                    Text("Create a layout from a preset to start.")
                }
            } actions: {
                Menu("New from preset") {
                    ForEach(LayoutPreset.allCases) { preset in
                        Button(preset.title) { model.addLayout(preset) }
                    }
                }
                .fixedSize()
            }
            .padding(12)
        } else {
            VStack(spacing: 10) {
                Text("Select a layout").foregroundStyle(.secondary)
                if let error = model.errorText {
                    Banner(tone: .danger, title: "Something went wrong", message: error, onDismiss: { model.dismissError() })
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectionHint: String {
        switch model.selectedZoneIDs.count {
        case 0: return "Click a zone to select it"
        case 1: return "Zone selected"
        default: return "\(model.selectedZoneIDs.count) zones selected"
        }
    }

    // MARK: Apps

    private var appsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Running apps").font(.headline)
                Spacer()
                Button { model.refreshApps() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Refresh running apps")
                    .help("Refresh running apps")
            }
            Text("Drag an app onto a zone").font(.footnote).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.runningApps) { app in
                        AppChip(title: app.name)
                            .draggable(app.bundleID)
                    }
                }
            }
        }
        .padding(12)
    }
}

/// Tracks whether this handle pushed a resize cursor, so every push is matched by exactly one pop.
@MainActor
private final class CursorHold: ObservableObject {
    @Published var pushed = false

    func hover(_ inside: Bool, _ cursor: NSCursor) {
        if inside, !pushed {
            cursor.push()
            pushed = true
        } else if !inside, pushed {
            NSCursor.pop()
            pushed = false
        }
    }

    func release() {
        if pushed {
            NSCursor.pop()
            pushed = false
        }
    }
}

/// A drag strip on one zone edge. Its own view so the cursor state lives with it.
private struct EdgeHandle: View {
    @ObservedObject var model: LayoutEditorModel
    let zoneID: UUID
    let edge: ZoneEdge
    let horizontal: Bool
    let thickness: CGFloat
    let length: CGFloat
    let center: CGPoint
    let size: CGSize
    @StateObject private var cursor = CursorHold()

    var body: some View {
        Color.clear
            .frame(width: horizontal ? thickness : length, height: horizontal ? length : thickness)
            .contentShape(Rectangle())
            .position(center)
            .onHover { inside in
                cursor.hover(inside, horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown)
            }
            .onDisappear { cursor.release() }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let t = horizontal ? Double(value.translation.width / size.width) : Double(value.translation.height / size.height)
                    model.dragEdge(zone: zoneID, edge: edge, translation: t)
                }
                .onEnded { _ in model.endEdgeDrag() })
    }
}

private struct AppChip: View {
    let title: String

    var body: some View {
        Text(title)
            .lineLimit(1)
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.5)))
    }
}

/// The selected display drawn to scale, with the layout's zones on it.
private struct MiniMap: View {
    @ObservedObject var model: LayoutEditorModel
    let layout: WMCore.Layout
    let display: DisplayIdentity

    var body: some View {
        let aspect = display.frame.height > 0 ? display.frame.width / display.frame.height : 16.0 / 10.0
        GeometryReader { proxy in
            let size = fit(aspect: aspect, in: proxy.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary, lineWidth: 2))
                ForEach(layout.zones) { zone in
                    zoneView(zone, size: size)
                }
                ForEach(layout.zones) { zone in
                    handles(zone, size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .dropDestination(for: String.self) { items, location in
                guard let bundleID = items.first, model.acceptsDrop(bundleID),
                      let zone = layout.zone(atX: Double(location.x / size.width), y: Double(location.y / size.height))
                else { return false }
                model.assign(bundleID: bundleID, to: zone.id)
                return true
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func fit(aspect: Double, in available: CGSize) -> CGSize {
        guard available.width > 0, available.height > 0 else { return .zero }
        let w = min(available.width, available.height * aspect)
        return CGSize(width: w, height: w / aspect)
    }

    private func zoneView(_ zone: Zone, size: CGSize) -> some View {
        let r = zone.rect
        let selected = model.selectedZoneIDs.contains(zone.id)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.accentColor.opacity(selected ? 0.30 : 0.15))
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: selected ? 2 : 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(zone.name).font(.caption.bold()).lineLimit(1)
                ForEach(layout.apps(in: zone.id), id: \.self) { bundleID in
                    HStack(spacing: 2) {
                        Text(model.name(for: bundleID)).lineLimit(1)
                        Button { model.unassign(bundleID) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(model.name(for: bundleID)) from zone")
                            .help("Remove from zone")
                    }
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.7)))
                    .foregroundStyle(Color.black)
                }
            }
            .padding(5)
        }
        .frame(width: r.width * size.width, height: r.height * size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            // Read the modifiers at tap time: Shift or Command adds or removes this zone from the selection.
            let flags = NSEvent.modifierFlags
            model.tapZone(zone.id, extend: flags.contains(.shift) || flags.contains(.command))
        }
        .offset(x: r.x * size.width, y: r.y * size.height)
    }

    /// Thin drag strips on the zone edges that are not on the display border.
    @ViewBuilder private func handles(_ zone: Zone, size: CGSize) -> some View {
        let r = zone.rect
        let thick: CGFloat = 8
        ForEach(ZoneEdge.allCases, id: \.self) { edge in
            if !isBorder(edge, r) {
                let horizontal = edge == .left || edge == .right
                let length = horizontal ? r.height * size.height : r.width * size.width
                let center: CGPoint = {
                    switch edge {
                    case .left: return CGPoint(x: r.x * size.width, y: r.midY * size.height)
                    case .right: return CGPoint(x: r.maxX * size.width, y: r.midY * size.height)
                    case .top: return CGPoint(x: r.midX * size.width, y: r.y * size.height)
                    case .bottom: return CGPoint(x: r.midX * size.width, y: r.maxY * size.height)
                    }
                }()
                EdgeHandle(
                    model: model,
                    zoneID: zone.id,
                    edge: edge,
                    horizontal: horizontal,
                    thickness: thick,
                    length: length,
                    center: center,
                    size: size
                )
            }
        }
    }

    private func isBorder(_ edge: ZoneEdge, _ r: NormalizedRect) -> Bool {
        let eps = 1e-6
        switch edge {
        case .left: return r.x < eps
        case .right: return r.maxX > 1 - eps
        case .top: return r.y < eps
        case .bottom: return r.maxY > 1 - eps
        }
    }
}
