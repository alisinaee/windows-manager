import SwiftUI
import WMCore

/// Layout editor: layouts on the left, the monitor mini map in the middle, running apps on the right.
/// Drag an app chip onto a zone to assign it; drag a zone edge to resize; tap a preset to start over.
struct LayoutEditorView: View {
    @ObservedObject var model: LayoutEditorModel

    var body: some View {
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
        .frame(minWidth: 840, minHeight: 480)
    }

    // MARK: Layout list

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Layouts").font(.headline)
            List(selection: Binding(get: { model.selectedID }, set: { model.selectedID = $0; model.selectedZoneID = nil })) {
                ForEach(model.layouts) { layout in
                    Text(layout.name).tag(layout.id as UUID?)
                }
            }
            Menu("New from preset") {
                ForEach(LayoutPreset.allCases) { preset in
                    Button(preset.title) { model.addLayout(preset) }
                }
            }
            Button("Delete layout", role: .destructive) { model.deleteSelected() }
                .disabled(model.selected == nil)
        }
        .padding(12)
    }

    // MARK: Mini map

    @ViewBuilder private var editor: some View {
        if let layout = model.selected, let display = model.selectedDisplay {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Name", text: Binding(get: { layout.name }, set: { model.rename($0) }))
                        .textFieldStyle(.roundedBorder)
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
                MiniMap(model: model, layout: layout, display: display)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Button("Split left | right") { model.splitSelectedZone(.vertical) }
                    Button("Split top / bottom") { model.splitSelectedZone(.horizontal) }
                    Button("Delete zone") { model.deleteSelectedZone() }
                    Spacer()
                    Text(model.selectedZoneID == nil ? "Click a zone to select it" : "Zone selected")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .disabled(model.selectedZoneID == nil)
                if let error = model.errorText {
                    Text(error).font(.footnote).foregroundStyle(Color.red)
                }
            }
            .padding(12)
        } else {
            VStack(spacing: 10) {
                Text(model.layouts.isEmpty ? "No layouts yet" : "Select a layout")
                    .foregroundStyle(.secondary)
                if model.displays.isEmpty { Text("No displays found").font(.footnote).foregroundStyle(.secondary) }
                if let error = model.errorText { Text(error).font(.footnote).foregroundStyle(Color.red) }
                Menu("New from preset") {
                    ForEach(LayoutPreset.allCases) { preset in
                        Button(preset.title) { model.addLayout(preset) }
                    }
                }
                .fixedSize()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                guard let bundleID = items.first,
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
        let selected = model.selectedZoneID == zone.id
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
        .onTapGesture { model.selectedZoneID = zone.id }
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
                Color.clear
                    .frame(width: horizontal ? thick : length, height: horizontal ? length : thick)
                    .contentShape(Rectangle())
                    .position(center)
                    .onHover { inside in
                        if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let t = horizontal ? Double(value.translation.width / size.width) : Double(value.translation.height / size.height)
                            model.dragEdge(zone: zone.id, edge: edge, translation: t)
                        }
                        .onEnded { _ in model.endEdgeDrag() })
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
