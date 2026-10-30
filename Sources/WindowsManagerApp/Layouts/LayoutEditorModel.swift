import AppKit
import SwiftUI
import WMCore

/// An app that can be dragged onto a zone.
struct RunningAppChip: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// A layout that was just deleted, kept so Undo can put it back at the same position.
struct DeletedLayout {
    let layout: WMCore.Layout
    let index: Int
}

/// State of the layout editor. No `@State` in this target (see MenuBarContent), so everything is here.
@MainActor
final class LayoutEditorModel: ObservableObject {
    @Published var layouts: [WMCore.Layout] = []
    /// Commits the name draft to the layout being left before the selection moves, then loads the new one's name.
    @Published var selectedID: UUID? {
        willSet { commitName() }
        didSet {
            nameDraft = selected?.name ?? ""
            if oldValue != selectedID {
                selectedZoneID = nil
                selectedZoneIDs = []
            }
        }
    }
    /// The zone that single-zone actions (split, delete) use. See `ZoneSelection.primary`.
    @Published var selectedZoneID: UUID?
    /// Every selected zone, for merging. A plain tap selects one zone; Shift or Command toggles zones.
    @Published var selectedZoneIDs: Set<UUID> = []
    @Published var displays: [DisplayIdentity] = []
    @Published var runningApps: [RunningAppChip] = []
    @Published var errorText: String?
    /// Set by a delete until the undo banner times out (about 6 seconds) or Undo is pressed.
    @Published private(set) var deletedLayout: DeletedLayout?
    /// Drives the delete confirmation dialog.
    @Published var confirmingDelete = false
    /// The name as typed; saved only by `commitName()` (on submit or focus loss), not per keystroke.
    @Published var nameDraft = ""
    /// Grid, merge and remove controls. Their closures call back into this model through `actionTarget`.
    let gridControls: LayoutGridControlsModel

    private let store: LayoutStore
    private let actionTarget: GridActionTarget
    private var edgeDragStart: Double?
    private var undoTimeout: Task<Void, Never>?

    init(store: LayoutStore = LayoutStore()) {
        self.store = store
        let target = GridActionTarget()
        actionTarget = target
        gridControls = LayoutGridControlsModel(actions: LayoutGridActions(
            applyGrid: { [target] rows, columns in target.editor?.applyGrid(rows: rows, columns: columns) },
            mergeSelected: { [target] in target.editor?.mergeSelectedZones() },
            removeSelected: { [target] in target.editor?.removeSelectedZoneIntoNeighbour() }
        ))
        target.editor = self
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
        nameDraft = selected?.name ?? ""
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
        selectedZoneIDs = []
        persist(layout)
    }

    func applyPreset(_ preset: LayoutPreset) {
        mutate { $0.zones = preset.makeZones(); $0.assignments = [:] }
        selectedZoneID = nil
        selectedZoneIDs = []
    }

    /// Tapping a zone selects it; with Shift or Command held (`extend`) it is toggled in the multi-selection.
    func tapZone(_ zoneID: UUID, extend: Bool) {
        let next = ZoneSelection.afterTap(selectedZoneIDs, tapped: zoneID, extend: extend)
        selectedZoneIDs = next
        selectedZoneID = ZoneSelection.primary(in: next, tapped: zoneID)
    }

    /// Deletes the selected layout and keeps it in `deletedLayout` so `undoDelete()` can restore it.
    func deleteSelected() {
        guard let index = selectedIndex else { return }
        let removed = layouts.remove(at: index)
        selectedID = layouts.first?.id
        do {
            try store.delete(id: removed.id)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        deletedLayout = DeletedLayout(layout: removed, index: index)
        undoTimeout?.cancel()
        undoTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.deletedLayout = nil
        }
    }

    /// Puts back the layout removed by the last delete and selects it.
    func undoDelete() {
        guard let deleted = deletedLayout else { return }
        undoTimeout?.cancel()
        deletedLayout = nil
        layouts.insert(deleted.layout, at: min(deleted.index, layouts.count))
        selectedID = deleted.layout.id
        persist(deleted.layout)
    }

    func dismissDeletedLayout() {
        undoTimeout?.cancel()
        deletedLayout = nil
    }

    func dismissError() { errorText = nil }

    func rename(_ name: String) { mutate { $0.name = name } }

    /// Saves the name draft to the selected layout. An empty name is rejected and the old name kept.
    func commitName() {
        guard let layout = selected else { return }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameDraft = layout.name
            errorText = "A layout needs a name. The old name was kept."
            return
        }
        if trimmed != layout.name { rename(trimmed) }
        nameDraft = trimmed
    }

    /// True when a dragged string may be assigned to a zone: a bundle id shape, or a running app's id.
    func acceptsDrop(_ bundleID: String) -> Bool {
        BundleIDValidation.accepts(bundleID, runningBundleIDs: Set(runningApps.map(\.bundleID)))
    }

    func setDisplay(_ key: String?) { mutate { $0.displayKey = key?.uppercased() } }

    func splitSelectedZone(_ axis: SplitAxis) {
        guard let zone = selectedZoneID else { return }
        mutate { layout in
            if let ids = layout.split(zoneID: zone, axis: axis) {
                selectedZoneID = ids.0
                selectedZoneIDs = [ids.0]
            }
        }
    }

    func deleteSelectedZone() {
        guard let zone = selectedZoneID else { return }
        mutate { $0.removeZone(zone) }
        selectedZoneID = nil
        selectedZoneIDs = []
    }

    // MARK: Grid, merge and remove (LayoutBuilder)

    /// Replaces the zones with a rows x columns grid. The apps on the old zones are dropped.
    func applyGrid(rows: Int, columns: Int) -> String? {
        guard let layout = selected else { return nil }
        do {
            let built = try LayoutBuilder.grid(rows: rows, columns: columns, name: layout.name, displayKey: layout.displayKey)
            mutate { $0.zones = built.zones; $0.assignments = [:] }
            selectedZoneID = nil
            selectedZoneIDs = []
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Merges the selected zones into one. Needs two or more zones that form a rectangle.
    func mergeSelectedZones() -> String? {
        guard let layout = selected else { return nil }
        do {
            let merged = try LayoutBuilder.merge(layout, zoneIDs: Array(selectedZoneIDs))
            mutate { $0.zones = merged.zones; $0.assignments = merged.assignments }
            selectedZoneID = merged.zones.first { selectedZoneIDs.contains($0.id) }?.id
            selectedZoneIDs = selectedZoneID.map { [$0] } ?? []
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Removes the selected zone and gives its area and apps to the neighbour with the longest shared edge.
    func removeSelectedZoneIntoNeighbour() -> String? {
        guard let layout = selected else { return nil }
        guard let zone = selectedZoneID else { return "Click a zone to select it first." }
        do {
            let removed = try LayoutBuilder.removeZone(layout, zoneID: zone)
            mutate { $0.zones = removed.zones; $0.assignments = removed.assignments }
            selectedZoneID = nil
            selectedZoneIDs = []
            return nil
        } catch {
            return error.localizedDescription
        }
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

/// Lets the grid action closures reach the editor without keeping it alive. Set once `init` has finished.
@MainActor
private final class GridActionTarget {
    weak var editor: LayoutEditorModel?
}

extension Notification.Name {
    /// Posted after a layout was saved; SnapMonitor can start late when the first layout appears.
    static let layoutsDidChange = Notification.Name("dev.windowsmanager.layoutsDidChange")
}
