import AppKit
import SwiftUI
import WMCore

/// An app that can be dragged onto a zone.
struct RunningAppChip: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// State of the layout editor. No `@State` in this target (see MenuBarContent), so everything is here.
@MainActor
final class LayoutEditorModel: ObservableObject {
    @Published var layouts: [WMCore.Layout] = []
    @Published var selectedID: UUID?
    @Published var selectedZoneID: UUID?
    @Published var displays: [DisplayIdentity] = []
    @Published var runningApps: [RunningAppChip] = []
    @Published var errorText: String?

    private let store: LayoutStore
    private var edgeDragStart: Double?

    init(store: LayoutStore = LayoutStore()) {
        self.store = store
        reload()
    }

    func reload() {
        displays = DisplayMap.current()
        refreshApps()
        do {
            layouts = try store.load()
            errorText = nil
        } catch {
            layouts = []
            errorText = error.localizedDescription
        }
        if selectedID == nil || !layouts.contains(where: { $0.id == selectedID }) { selectedID = layouts.first?.id }
    }

    func refreshApps() {
        var seen = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningAppChip? in
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return RunningAppChip(bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var selectedIndex: Int? { layouts.firstIndex { $0.id == selectedID } }
    var selected: WMCore.Layout? { selectedIndex.map { layouts[$0] } }

    /// The display the selected layout is drawn on: its own, else the main one.
    var selectedDisplay: DisplayIdentity? {
        if let key = selected?.displayKey, let match = displays.first(where: { $0.uuid.uppercased() == key }) { return match }
        return displays.first { $0.isMain } ?? displays.first
    }

    func name(for bundleID: String) -> String {
        runningApps.first { $0.bundleID == bundleID }?.name ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    // MARK: Changes (each one saves)

    func addLayout(_ preset: LayoutPreset) {
        var layout = preset.makeLayout()
        layout.name = uniqueName(preset.title)
        layouts.append(layout)
        selectedID = layout.id
        selectedZoneID = nil
        persist(layout)
    }

    func applyPreset(_ preset: LayoutPreset) {
        mutate { $0.zones = preset.makeZones(); $0.assignments = [:] }
        selectedZoneID = nil
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        layouts.removeAll { $0.id == id }
        selectedID = layouts.first?.id
        do { try store.delete(id: id) } catch { errorText = error.localizedDescription }
    }

    func rename(_ name: String) { mutate { $0.name = name } }

    func setDisplay(_ key: String?) { mutate { $0.displayKey = key?.uppercased() } }

    func splitSelectedZone(_ axis: SplitAxis) {
        guard let zone = selectedZoneID else { return }
        mutate { layout in
            if let ids = layout.split(zoneID: zone, axis: axis) { selectedZoneID = ids.0 }
        }
    }

    func deleteSelectedZone() {
        guard let zone = selectedZoneID else { return }
        mutate { $0.removeZone(zone) }
        selectedZoneID = nil
    }

    func assign(bundleID: String, to zoneID: UUID) {
        mutate { $0.assign(bundleID: bundleID, to: zoneID) }
    }

    func unassign(_ bundleID: String) { mutate { $0.unassign(bundleID: bundleID) } }

    /// Edge drag: `translation` is in normalized units along the edge's axis since the drag began.
    func dragEdge(zone: UUID, edge: ZoneEdge, translation: Double) {
        guard let i = selectedIndex, let z = layouts[i].zones.first(where: { $0.id == zone }) else { return }
        if edgeDragStart == nil {
            switch edge {
            case .left: edgeDragStart = z.rect.x
            case .right: edgeDragStart = z.rect.maxX
            case .top: edgeDragStart = z.rect.y
            case .bottom: edgeDragStart = z.rect.maxY
            }
        }
        layouts[i].moveEdge(of: zone, edge: edge, to: (edgeDragStart ?? 0) + translation)
    }

    func endEdgeDrag() {
        edgeDragStart = nil
        if let layout = selected { persist(layout) }
    }

    // MARK: Private

    private func mutate(_ change: (inout WMCore.Layout) -> Void) {
        guard let i = selectedIndex else { return }
        change(&layouts[i])
        persist(layouts[i])
    }

    private func persist(_ layout: WMCore.Layout) {
        do {
            try store.upsert(layout); errorText = nil
            NotificationCenter.default.post(name: .layoutsDidChange, object: nil)
        } catch { errorText = error.localizedDescription }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(layouts.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

extension Notification.Name {
    /// Posted after a layout was saved; SnapMonitor can start late when the first layout appears.
    static let layoutsDidChange = Notification.Name("dev.windowsmanager.layoutsDidChange")
}
