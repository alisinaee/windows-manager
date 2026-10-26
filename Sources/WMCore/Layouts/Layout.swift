import CoreGraphics
import Foundation

// The layout model (phase P4.2): named zones inside a display, in normalized 0..1 coordinates
// (origin top-left, y grows down), plus which apps belong in which zone. Applying a layout to real
// windows is a later phase; this file is pure data and geometry.

/// A rectangle inside a display, in 0..1 units of the display's frame.
public struct NormalizedRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }
}

public struct Zone: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var rect: NormalizedRect

    public init(id: UUID = UUID(), name: String, rect: NormalizedRect) {
        self.id = id
        self.name = name
        self.rect = rect
    }
}

public enum SplitAxis: String, Codable, Sendable {
    /// Cut with a vertical line: left and right halves.
    case vertical
    /// Cut with a horizontal line: top and bottom halves.
    case horizontal
}

public enum ZoneEdge: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom
}

public struct Layout: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Uppercase display UUID this layout is for; nil matches any display.
    public var displayKey: String?
    public var zones: [Zone]
    /// Zone id string -> bundle ids of the apps that belong there.
    public var assignments: [String: [String]]

    public static let minZoneSize = 0.05

    public init(id: UUID = UUID(), name: String, displayKey: String? = nil, zones: [Zone] = [],
                assignments: [String: [String]] = [:]) {
        self.id = id
        self.name = name
        self.displayKey = displayKey?.uppercased()
        self.zones = zones
        self.assignments = assignments
    }

    public func matches(display: DisplayIdentity) -> Bool {
        displayKey == nil || displayKey == display.uuid.uppercased()
    }

    // MARK: Hit testing

    /// The zone under a normalized point (the topmost, i.e. last, zone wins on overlap).
    public func zone(atX x: Double, y: Double) -> Zone? {
        zones.last { $0.rect.contains(x: x, y: y) }
    }

    /// The zone under a point of a display frame (same coordinate space as `frame`).
    public func zone(at point: CGPoint, in frame: CGRect) -> Zone? {
        guard frame.width > 0, frame.height > 0, frame.contains(point) else { return nil }
        return zone(atX: Double((point.x - frame.minX) / frame.width), y: Double((point.y - frame.minY) / frame.height))
    }

    // MARK: Assignments

    public func apps(in zoneID: UUID) -> [String] { assignments[zoneID.uuidString] ?? [] }

    /// Puts an app in a zone, removing it from any other zone first (an app lives in one zone).
    public mutating func assign(bundleID: String, to zoneID: UUID) {
        guard zones.contains(where: { $0.id == zoneID }) else { return }
        unassign(bundleID: bundleID)
        assignments[zoneID.uuidString, default: []].append(bundleID)
    }

    public mutating func unassign(bundleID: String) {
        for key in Array(assignments.keys) {
            assignments[key]?.removeAll { $0 == bundleID }
            if assignments[key]?.isEmpty == true { assignments[key] = nil }
        }
    }

    // MARK: Editing

    /// Splits a zone in two at `fraction` (0..1 along the axis, within the zone). Returns the two new zone ids.
    @discardableResult
    public mutating func split(zoneID: UUID, axis: SplitAxis, fraction: Double = 0.5) -> (UUID, UUID)? {
        guard let index = zones.firstIndex(where: { $0.id == zoneID }) else { return nil }
        let zone = zones[index]
        let f = min(max(fraction, 0.1), 0.9)
        let a: NormalizedRect
        let b: NormalizedRect
        switch axis {
        case .vertical:
            a = NormalizedRect(x: zone.rect.x, y: zone.rect.y, width: zone.rect.width * f, height: zone.rect.height)
            b = NormalizedRect(x: zone.rect.x + a.width, y: zone.rect.y, width: zone.rect.width - a.width, height: zone.rect.height)
        case .horizontal:
            a = NormalizedRect(x: zone.rect.x, y: zone.rect.y, width: zone.rect.width, height: zone.rect.height * f)
            b = NormalizedRect(x: zone.rect.x, y: zone.rect.y + a.height, width: zone.rect.width, height: zone.rect.height - a.height)
        }
        guard a.width >= Self.minZoneSize, a.height >= Self.minZoneSize,
              b.width >= Self.minZoneSize, b.height >= Self.minZoneSize else { return nil }
        let first = Zone(name: zone.name, rect: a)
        let second = Zone(name: zone.name + " 2", rect: b)
        zones.replaceSubrange(index...index, with: [first, second])
        // The old zone's apps stay with the first half.
        if let apps = assignments.removeValue(forKey: zoneID.uuidString) { assignments[first.id.uuidString] = apps }
        return (first.id, second.id)
    }

    /// Removes a zone and its assignments.
    public mutating func removeZone(_ zoneID: UUID) {
        zones.removeAll { $0.id == zoneID }
        assignments[zoneID.uuidString] = nil
    }

    /// Moves one edge of a zone to `value` (0..1). Zones that share that line move with it, so dragging a
    /// divider between two zones resizes both. The move is clamped so no touched zone gets smaller than
    /// `minZoneSize` and the edge stays inside the display.
    public mutating func moveEdge(of zoneID: UUID, edge: ZoneEdge, to value: Double) {
        guard let zone = zones.first(where: { $0.id == zoneID }) else { return }
        let eps = 1e-6
        let horizontalEdge = (edge == .left || edge == .right)
        let old: Double
        switch edge {
        case .left: old = zone.rect.x
        case .right: old = zone.rect.maxX
        case .top: old = zone.rect.y
        case .bottom: old = zone.rect.maxY
        }
        // Zones whose leading edge (left/top) or trailing edge (right/bottom) sits on the same line.
        func lead(_ r: NormalizedRect) -> Double { horizontalEdge ? r.x : r.y }
        func trail(_ r: NormalizedRect) -> Double { horizontalEdge ? r.maxX : r.maxY }
        let leads = zones.indices.filter { abs(lead(zones[$0].rect) - old) < eps }
        let trails = zones.indices.filter { abs(trail(zones[$0].rect) - old) < eps }
        // Bounds: leading edges may not pass trail - min; trailing edges may not go below lead + min.
        var low = 0.0
        var high = 1.0
        for i in leads { high = min(high, trail(zones[i].rect) - Self.minZoneSize) }
        for i in trails { low = max(low, lead(zones[i].rect) + Self.minZoneSize) }
        guard low <= high else { return }
        let target = min(max(value, low), high)
        for i in leads {
            if horizontalEdge {
                zones[i].rect.width -= target - zones[i].rect.x
                zones[i].rect.x = target
            } else {
                zones[i].rect.height -= target - zones[i].rect.y
                zones[i].rect.y = target
            }
        }
        for i in trails {
            if horizontalEdge { zones[i].rect.width = target - zones[i].rect.x }
            else { zones[i].rect.height = target - zones[i].rect.y }
        }
    }
}

// MARK: Geometry

public enum LayoutGeometry {
    /// The screen frame of a zone on a display. `displayFrame` is usually the display's visible frame, in
    /// whatever coordinate space the caller wants back. `gap` is the space between zones and also the margin
    /// at the display edge: an edge on the display border is inset by `gap`, an inner edge by `gap / 2`.
    public static func frame(of rect: NormalizedRect, in displayFrame: CGRect, gap: CGFloat = 0) -> CGRect {
        let eps = 1e-6
        let g = max(gap, 0)
        let left = displayFrame.minX + CGFloat(rect.x) * displayFrame.width
        let right = displayFrame.minX + CGFloat(rect.maxX) * displayFrame.width
        let top = displayFrame.minY + CGFloat(rect.y) * displayFrame.height
        let bottom = displayFrame.minY + CGFloat(rect.maxY) * displayFrame.height
        let l = left + (rect.x < eps ? g : g / 2)
        let r = right - (rect.maxX > 1 - eps ? g : g / 2)
        let t = top + (rect.y < eps ? g : g / 2)
        let b = bottom - (rect.maxY > 1 - eps ? g : g / 2)
        return CGRect(x: l, y: t, width: max(r - l, 0), height: max(b - t, 0))
    }

    public static func frame(of zone: Zone, in displayFrame: CGRect, gap: CGFloat = 0) -> CGRect {
        frame(of: zone.rect, in: displayFrame, gap: gap)
    }
}

// MARK: Presets

public enum LayoutPreset: String, CaseIterable, Sendable, Identifiable {
    case halves, thirds, quarters, twoThirdsOneThird, center

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .halves: return "Halves"
        case .thirds: return "Thirds"
        case .quarters: return "Quarters"
        case .twoThirdsOneThird: return "2/3 + 1/3"
        case .center: return "Center"
        }
    }

    /// Fresh zones (new ids each call).
    public func makeZones() -> [Zone] {
        func z(_ name: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Zone {
            Zone(name: name, rect: NormalizedRect(x: x, y: y, width: w, height: h))
        }
        switch self {
        case .halves:
            return [z("Left", 0, 0, 0.5, 1), z("Right", 0.5, 0, 0.5, 1)]
        case .thirds:
            let t = 1.0 / 3.0
            return [z("Left", 0, 0, t, 1), z("Middle", t, 0, t, 1), z("Right", 2 * t, 0, 1 - 2 * t, 1)]
        case .quarters:
            return [z("Top left", 0, 0, 0.5, 0.5), z("Top right", 0.5, 0, 0.5, 0.5),
                    z("Bottom left", 0, 0.5, 0.5, 0.5), z("Bottom right", 0.5, 0.5, 0.5, 0.5)]
        case .twoThirdsOneThird:
            let t = 2.0 / 3.0
            return [z("Main", 0, 0, t, 1), z("Side", t, 0, 1 - t, 1)]
        case .center:
            return [z("Center", 0.15, 0.1, 0.7, 0.8)]
        }
    }

    public func makeLayout(displayKey: String? = nil) -> Layout {
        Layout(name: title, displayKey: displayKey, zones: makeZones())
    }
}
