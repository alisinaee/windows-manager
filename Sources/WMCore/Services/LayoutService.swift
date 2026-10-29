import CoreGraphics
import Foundation

// Layout CRUD for the CLI and tests (P6.89): a UI-free layer over LayoutStore. A layout is found by id (UUID)
// or by name (case-insensitive). Names are unique.

public final class LayoutService: @unchecked Sendable {
    private let store: LayoutStore

    public init(store: LayoutStore = LayoutStore()) {
        self.store = store
    }

    // MARK: Read

    public func list() throws -> [Layout] { try load() }

    public func get(_ idOrName: String) throws -> Layout {
        let all = try load()
        return try find(idOrName, in: all)
    }

    public func zones(of idOrName: String) throws -> [Zone] { try get(idOrName).zones }

    // MARK: Create / update / delete

    @discardableResult
    public func create(name: String, displayKey: String? = nil, zones: [Zone] = []) throws -> Layout {
        let all = try load()
        let clean = try Self.cleanName(name)
        try Self.ensureUnique(clean, in: all, except: nil)
        try Self.validate(zones: zones)
        let layout = Layout(name: clean, displayKey: Self.cleanKey(displayKey), zones: zones)
        try save { try store.upsert(layout) }
        return layout
    }

    /// Saves a layout from window frames: each frame becomes a zone, normalized against `displayFrame`
    /// (same coordinate space). Frames are clamped into the display. `overwrite` replaces a layout of the same name.
    @discardableResult
    public func saveFromFrames(name: String, displayKey: String? = nil, displayFrame: CGRect, frames: [CGRect],
                               zoneNames: [String] = [], overwrite: Bool = false) throws -> Layout {
        guard displayFrame.width > 0, displayFrame.height > 0 else { throw ServiceError.invalid("Display frame is empty.") }
        guard !frames.isEmpty else { throw ServiceError.invalid("No frames to save.") }
        let all = try load()
        let clean = try Self.cleanName(name)
        let existing = all.first { $0.name.caseInsensitiveCompare(clean) == .orderedSame }
        if existing != nil, !overwrite { throw ServiceError.conflict("A layout named \"\(clean)\" already exists.") }
        let zones: [Zone] = frames.enumerated().map { i, frame in
            let r = frame.intersection(displayFrame)
            let rect = NormalizedRect(x: Double((r.minX - displayFrame.minX) / displayFrame.width),
                                      y: Double((r.minY - displayFrame.minY) / displayFrame.height),
                                      width: Double(r.width / displayFrame.width),
                                      height: Double(r.height / displayFrame.height))
            let label = i < zoneNames.count && !zoneNames[i].isEmpty ? zoneNames[i] : "Zone \(i + 1)"
            return Zone(name: label, rect: rect)
        }
        try Self.validate(zones: zones)
        let layout = Layout(id: existing?.id ?? UUID(), name: clean, displayKey: Self.cleanKey(displayKey), zones: zones)
        try save { try store.upsert(layout) }
        return layout
    }

    @discardableResult
    public func rename(_ idOrName: String, to newName: String) throws -> Layout {
        let all = try load()
        var layout = try find(idOrName, in: all)
        let clean = try Self.cleanName(newName)
        try Self.ensureUnique(clean, in: all, except: layout.id)
        layout.name = clean
        try save { try store.upsert(layout) }
        return layout
    }

    /// Sets the display a layout is for; nil makes it match any display.
    @discardableResult
    public func setDisplay(_ idOrName: String, displayKey: String?) throws -> Layout {
        var layout = try find(idOrName, in: try load())
        layout.displayKey = Self.cleanKey(displayKey)
        try save { try store.upsert(layout) }
        return layout
    }

    @discardableResult
    public func addZone(to idOrName: String, name: String, rect: NormalizedRect) throws -> Layout {
        var layout = try find(idOrName, in: try load())
        let zone = Zone(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Zone \(layout.zones.count + 1)" : name, rect: rect)
        try Self.validate(zones: [zone])
        layout.zones.append(zone)
        try save { try store.upsert(layout) }
        return layout
    }

    /// Renames and/or moves a zone (any argument left nil stays as it is). The new rect is validated like a new zone.
    @discardableResult
    public func updateZone(in idOrName: String, zone zoneRef: String, name: String? = nil, rect: NormalizedRect? = nil) throws -> Layout {
        var layout = try find(idOrName, in: try load())
        let zone = try Self.findZone(zoneRef, in: layout)
        guard let i = layout.zones.firstIndex(where: { $0.id == zone.id }) else { throw ServiceError.notFound("No zone \"\(zoneRef)\".") }
        if let name {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw ServiceError.invalid("Zone name is empty.") }
            layout.zones[i].name = clean
        }
        if let rect { layout.zones[i].rect = rect }
        try Self.validate(zones: [layout.zones[i]])
        try save { try store.upsert(layout) }
        return layout
    }

    /// Removes a zone by id or name, and its app assignments.
    @discardableResult
    public func removeZone(from idOrName: String, zone zoneRef: String) throws -> Layout {
        var layout = try find(idOrName, in: try load())
        let zone = try Self.findZone(zoneRef, in: layout)
        layout.removeZone(zone.id)
        try save { try store.upsert(layout) }
        return layout
    }

    @discardableResult
    public func assign(bundleID: String, to zoneRef: String, in idOrName: String) throws -> Layout {
        var layout = try find(idOrName, in: try load())
        let zone = try Self.findZone(zoneRef, in: layout)
        guard BundleIDValidation.looksLikeBundleID(bundleID) else { throw ServiceError.invalid("\"\(bundleID)\" is not a bundle id.") }
        layout.assign(bundleID: bundleID, to: zone.id)
        try save { try store.upsert(layout) }
        return layout
    }

    @discardableResult
    public func unassign(bundleID: String, in idOrName: String) throws -> Layout {
        var layout = try find(idOrName, in: try load())
        layout.unassign(bundleID: bundleID)
        try save { try store.upsert(layout) }
        return layout
    }

    public func delete(_ idOrName: String) throws {
        let layout = try find(idOrName, in: try load())
        try save { try store.delete(id: layout.id) }
    }

    // MARK: Internals

    private func load() throws -> [Layout] {
        do { return try store.load() } catch { throw ServiceError.wrap(error) }
    }

    private func save(_ body: () throws -> Void) throws {
        do { try body() } catch { throw ServiceError.wrap(error) }
    }

    private func find(_ ref: String, in all: [Layout]) throws -> Layout {
        let t = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: t), let hit = all.first(where: { $0.id == id }) { return hit }
        if let hit = all.first(where: { $0.name.caseInsensitiveCompare(t) == .orderedSame }) { return hit }
        throw ServiceError.notFound("No layout \"\(ref)\".")
    }

    private static func findZone(_ ref: String, in layout: Layout) throws -> Zone {
        let t = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: t), let hit = layout.zones.first(where: { $0.id == id }) { return hit }
        if let hit = layout.zones.first(where: { $0.name.caseInsensitiveCompare(t) == .orderedSame }) { return hit }
        throw ServiceError.notFound("No zone \"\(ref)\" in layout \"\(layout.name)\".")
    }

    private static func cleanName(_ name: String) throws -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw ServiceError.invalid("Layout name is empty.") }
        return t
    }

    private static func cleanKey(_ key: String?) -> String? {
        let t = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    private static func ensureUnique(_ name: String, in all: [Layout], except id: UUID?) throws {
        if all.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ServiceError.conflict("A layout named \"\(name)\" already exists.")
        }
    }

    private static func validate(zones: [Zone]) throws {
        let eps = 1e-6
        for z in zones {
            let r = z.rect
            guard r.x >= -eps, r.y >= -eps, r.maxX <= 1 + eps, r.maxY <= 1 + eps else {
                throw ServiceError.invalid("Zone \"\(z.name)\" is outside the display (0...1).")
            }
            guard r.width >= Layout.minZoneSize - eps, r.height >= Layout.minZoneSize - eps else {
                throw ServiceError.invalid("Zone \"\(z.name)\" is smaller than \(Layout.minZoneSize) of the display.")
            }
        }
    }
}
