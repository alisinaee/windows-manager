import CoreGraphics
import Foundation

// Pure layout builders on top of `Layout` (phase P4.1): regular grids, weighted rows and columns, splits by
// zone id, merging adjacent zones, removing a zone into its neighbour, adding custom zones and normalizing
// coordinates. Everything here returns a new `Layout` and never touches the store or the screen.

public enum LayoutBuilderError: Error, Equatable, LocalizedError {
    case gridOutOfRange
    case invalidWeights
    case invalidFraction
    case zoneNotFound
    case duplicateZone
    case needsAtLeastTwoZones
    case notAdjacent
    case notRectangular
    case splitRejected
    case noNeighbour
    case cannotAbsorb
    case zoneTooSmall
    case overlapsExisting

    public var errorDescription: String? {
        switch self {
        case .gridOutOfRange: return "A grid has 1 to 6 rows and 1 to 6 columns."
        case .invalidWeights: return "Each row or column needs a positive size of at least 3% of the display."
        case .invalidFraction: return "A split must be between 10% and 90%."
        case .zoneNotFound: return "That zone is not in this layout."
        case .duplicateZone: return "The same zone was picked twice."
        case .needsAtLeastTwoZones: return "Pick at least two zones to merge."
        case .notAdjacent: return "Only zones that touch each other can be merged."
        case .notRectangular: return "The selected zones do not form one rectangle, so they cannot be merged."
        case .splitRejected: return "The zone is too small to split."
        case .noNeighbour: return "This zone has no neighbour to give its area to."
        case .cannotAbsorb: return "The neighbour cannot take this zone's area without an L-shape. Remove a different zone or change the layout by hand."
        case .zoneTooSmall: return "The zone is smaller than 3% of the display."
        case .overlapsExisting: return "The new zone overlaps an existing zone by more than 2%."
        }
    }
}

public enum LayoutBuilder {
    /// Rows and columns allowed in a grid, and also the number of weights accepted by `weightedRows/Columns`.
    public static let gridRange: ClosedRange<Int> = 1...6
    /// Smallest width or height a zone may have after building or normalizing.
    public static let minimumZoneSide = 0.03
    /// Largest share of a new custom zone that may overlap existing zones.
    public static let maximumOverlapShare = 0.02
    /// Coordinates are snapped to this step by `normalize`.
    public static let snapStep = 0.001

    private static let eps = 1e-9

    // MARK: Grids

    /// A `rows` x `columns` grid of equal cells, zones in reading order (row by row).
    public static func grid(rows: Int, columns: Int, name: String, displayKey: String? = nil) throws -> Layout {
        guard gridRange.contains(rows), gridRange.contains(columns) else { throw LayoutBuilderError.gridOutOfRange }
        let rowStrips = try weightedRows(Array(repeating: 1.0, count: rows))
        let columnStrips = try weightedColumns(Array(repeating: 1.0, count: columns))
        var zones: [Zone] = []
        for (r, row) in rowStrips.enumerated() {
            for (c, column) in columnStrips.enumerated() {
                let rect = NormalizedRect(x: column.rect.x, y: row.rect.y, width: column.rect.width, height: row.rect.height)
                zones.append(Zone(name: "Row \(r + 1), Column \(c + 1)", rect: rect))
            }
        }
        return Layout(name: name, displayKey: displayKey, zones: zones)
    }

    /// Full-height columns whose widths are proportional to `weights` (normalized to sum to 1).
    public static func weightedColumns(_ weights: [Double]) throws -> [Zone] {
        try strips(weights, horizontal: true)
    }

    /// Full-width rows whose heights are proportional to `weights` (normalized to sum to 1).
    public static func weightedRows(_ weights: [Double]) throws -> [Zone] {
        try strips(weights, horizontal: false)
    }

    private static func strips(_ weights: [Double], horizontal: Bool) throws -> [Zone] {
        let shares = try normalizedWeights(weights)
        var zones: [Zone] = []
        var start = 0.0
        for (i, share) in shares.enumerated() {
            // The last edge is exactly 1 so rounding never leaves a gap at the display edge.
            let end = i == shares.count - 1 ? 1.0 : start + share
            let rect = horizontal
                ? NormalizedRect(x: start, y: 0, width: end - start, height: 1)
                : NormalizedRect(x: 0, y: start, width: 1, height: end - start)
            zones.append(Zone(name: horizontal ? "Column \(i + 1)" : "Row \(i + 1)", rect: rect))
            start = end
        }
        return zones
    }

    static func normalizedWeights(_ weights: [Double]) throws -> [Double] {
        guard gridRange.contains(weights.count), weights.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw LayoutBuilderError.invalidWeights
        }
        let sum = weights.reduce(0, +)
        let shares = weights.map { $0 / sum }
        guard shares.allSatisfy({ $0 >= minimumZoneSide }) else { throw LayoutBuilderError.invalidWeights }
        return shares
    }

    // MARK: Splits

    /// Splits a zone with a vertical cut: `fraction` of its width goes to the left half.
    public static func splitVertically(_ layout: Layout, zoneID: UUID, fraction: Double = 0.5) throws -> Layout {
        try split(layout, zoneID: zoneID, axis: .vertical, fraction: fraction)
    }

    /// Splits a zone with a horizontal cut: `fraction` of its height goes to the top half.
    public static func splitHorizontally(_ layout: Layout, zoneID: UUID, fraction: Double = 0.5) throws -> Layout {
        try split(layout, zoneID: zoneID, axis: .horizontal, fraction: fraction)
    }

    private static func split(_ layout: Layout, zoneID: UUID, axis: SplitAxis, fraction: Double) throws -> Layout {
        // `Layout.split` clamps to 0.1...0.9; reject outside that range instead of silently changing the request.
        guard fraction.isFinite, (0.1...0.9).contains(fraction) else { throw LayoutBuilderError.invalidFraction }
        guard layout.zones.contains(where: { $0.id == zoneID }) else { throw LayoutBuilderError.zoneNotFound }
        var copy = layout
        guard copy.split(zoneID: zoneID, axis: axis, fraction: fraction) != nil else {
            throw LayoutBuilderError.splitRejected
        }
        return copy
    }

    // MARK: Merge

    /// Merges two or more zones that touch each other into one zone covering their union. The union must be
    /// exactly one rectangle with no gaps and no overlaps. The merged zone keeps the id and name of the zone
    /// that comes first in the layout, and gets the apps of all the merged zones.
    public static func merge(_ layout: Layout, zoneIDs: [UUID]) throws -> Layout {
        guard Set(zoneIDs).count == zoneIDs.count else { throw LayoutBuilderError.duplicateZone }
        guard zoneIDs.count >= 2 else { throw LayoutBuilderError.needsAtLeastTwoZones }
        let indices = layout.zones.indices.filter { zoneIDs.contains(layout.zones[$0].id) }
        guard indices.count == zoneIDs.count else { throw LayoutBuilderError.zoneNotFound }

        let members = indices.map { layout.zones[$0] }
        guard isConnected(members.map(\.rect)) else { throw LayoutBuilderError.notAdjacent }
        let box = boundingBox(members.map(\.rect))
        let sumOfAreas = members.reduce(0.0) { $0 + area($1.rect) }
        let pairOverlap = members.indices.flatMap { i in
            members.indices.filter { $0 > i }.map { overlapArea(members[i].rect, members[$0].rect) }
        }.reduce(0.0, +)
        // Non-overlapping pieces that add up to their bounding box tile it exactly.
        guard pairOverlap < eps, abs(sumOfAreas - area(box)) < eps else { throw LayoutBuilderError.notRectangular }

        var apps: [String] = []
        for member in members {
            for app in layout.apps(in: member.id) where !apps.contains(app) { apps.append(app) }
        }
        let keeper = members[0]
        var copy = layout
        copy.zones = layout.zones.enumerated().compactMap { offset, zone in
            if offset == indices[0] { return Zone(id: keeper.id, name: keeper.name, rect: box) }
            return indices.contains(offset) ? nil : zone
        }
        for member in members.dropFirst() { copy.assignments[member.id.uuidString] = nil }
        copy.assignments[keeper.id.uuidString] = apps.isEmpty ? nil : apps
        return copy
    }

    // MARK: Remove

    /// Removes a zone. Its area goes to the neighbour that shares the longest edge with it (the first one in the
    /// layout wins a tie), and the removed zone's apps are added to that neighbour. Throws `cannotAbsorb` when
    /// the neighbour would not stay a rectangle.
    public static func removeZone(_ layout: Layout, zoneID: UUID) throws -> Layout {
        guard let index = layout.zones.firstIndex(where: { $0.id == zoneID }) else {
            throw LayoutBuilderError.zoneNotFound
        }
        let removed = layout.zones[index]
        var best: (index: Int, length: Double)?
        for i in layout.zones.indices where i != index {
            let length = sharedEdgeLength(removed.rect, layout.zones[i].rect)
            guard length > eps else { continue }
            if best == nil || length > best!.length + eps { best = (i, length) }
        }
        guard let target = best else { throw LayoutBuilderError.noNeighbour }
        let neighbour = layout.zones[target.index]
        let union = boundingBox([neighbour.rect, removed.rect])
        guard abs(area(union) - area(neighbour.rect) - area(removed.rect)) < eps else {
            throw LayoutBuilderError.cannotAbsorb
        }

        var copy = layout
        copy.zones[target.index].rect = union
        var apps = layout.apps(in: neighbour.id)
        for app in layout.apps(in: removed.id) where !apps.contains(app) { apps.append(app) }
        copy.assignments[neighbour.id.uuidString] = apps.isEmpty ? nil : apps
        copy.assignments[removed.id.uuidString] = nil
        copy.zones.remove(at: index)
        return copy
    }

    // MARK: Custom zones

    /// Adds a zone at `rect`, clipped to the display (0...1). It is rejected when it is smaller than 3% of the
    /// display in either direction, or when overlapping existing zones covers more than 2% of its own area.
    public static func addCustomZone(_ layout: Layout, rect: NormalizedRect, name: String? = nil) throws -> Layout {
        let clipped = clip(rect)
        guard clipped.width >= minimumZoneSide, clipped.height >= minimumZoneSide else {
            throw LayoutBuilderError.zoneTooSmall
        }
        let overlap = layout.zones.reduce(0.0) { $0 + overlapArea(clipped, $1.rect) }
        guard overlap <= maximumOverlapShare * area(clipped) else { throw LayoutBuilderError.overlapsExisting }
        var copy = layout
        copy.zones.append(Zone(name: name ?? "Custom \(layout.zones.count + 1)", rect: clipped))
        return copy
    }

    // MARK: Normalize

    /// Snaps every coordinate to `snapStep`, clamps to 0...1, and drops zones narrower or shorter than
    /// `minimumZoneSide`. Assignments of dropped zones are dropped too.
    public static func normalize(_ layout: Layout) -> Layout {
        var copy = layout
        var kept: [Zone] = []
        for var zone in layout.zones {
            let x0 = snap(zone.rect.x)
            let x1 = snap(zone.rect.maxX)
            let y0 = snap(zone.rect.y)
            let y1 = snap(zone.rect.maxY)
            let rect = NormalizedRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            guard rect.width >= minimumZoneSide, rect.height >= minimumZoneSide else { continue }
            zone.rect = rect
            kept.append(zone)
        }
        copy.zones = kept
        let keptIDs = Set(kept.map { $0.id.uuidString })
        copy.assignments = layout.assignments.filter { keptIDs.contains($0.key) }
        return copy
    }

    // MARK: Geometry helpers

    static func snap(_ value: Double) -> Double {
        min(max((value / snapStep).rounded() * snapStep, 0), 1)
    }

    static func clip(_ rect: NormalizedRect) -> NormalizedRect {
        let x0 = min(max(rect.x, 0), 1)
        let x1 = min(max(rect.maxX, 0), 1)
        let y0 = min(max(rect.y, 0), 1)
        let y1 = min(max(rect.maxY, 0), 1)
        return NormalizedRect(x: x0, y: y0, width: max(x1 - x0, 0), height: max(y1 - y0, 0))
    }

    static func area(_ rect: NormalizedRect) -> Double { rect.width * rect.height }

    static func boundingBox(_ rects: [NormalizedRect]) -> NormalizedRect {
        let minX = rects.map(\.x).min() ?? 0
        let minY = rects.map(\.y).min() ?? 0
        let maxX = rects.map(\.maxX).max() ?? 0
        let maxY = rects.map(\.maxY).max() ?? 0
        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func overlapArea(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
        let w = min(a.maxX, b.maxX) - max(a.x, b.x)
        let h = min(a.maxY, b.maxY) - max(a.y, b.y)
        return w > 0 && h > 0 ? w * h : 0
    }

    /// Length of the edge two rectangles share (0 when they only touch at a corner or not at all).
    static func sharedEdgeLength(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
        if abs(a.maxX - b.x) < eps || abs(b.maxX - a.x) < eps {
            let length = min(a.maxY, b.maxY) - max(a.y, b.y)
            if length > eps { return length }
        }
        if abs(a.maxY - b.y) < eps || abs(b.maxY - a.y) < eps {
            let length = min(a.maxX, b.maxX) - max(a.x, b.x)
            if length > eps { return length }
        }
        return 0
    }

    /// True when the rectangles form one group in which every piece is reachable through shared edges.
    static func isConnected(_ rects: [NormalizedRect]) -> Bool {
        guard !rects.isEmpty else { return false }
        var seen: Set<Int> = [0]
        var queue = [0]
        while let current = queue.popLast() {
            for next in rects.indices where !seen.contains(next) && sharedEdgeLength(rects[current], rects[next]) > eps {
                seen.insert(next)
                queue.append(next)
            }
        }
        return seen.count == rects.count
    }
}
