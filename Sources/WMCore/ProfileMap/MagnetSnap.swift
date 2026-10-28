import CoreGraphics
import Foundation

// Magnet mode (G3): while a tile is dragged or resized, its edges stick to the monitor edges and to other
// tiles' edges within a screen distance, and the lines they stuck to are reported so the map can draw guides.
// Pure value math on canvas rects (real screen points).

public enum MagnetSnap {
    /// Snap distance on screen, in view points. Divide by the map zoom to get canvas points.
    public static let screenThreshold: CGFloat = 8

    /// A guide line the dragged rect stuck to.
    public struct Guide: Equatable, Hashable, Sendable {
        public enum Axis: Hashable, Sendable { case vertical, horizontal }
        public var axis: Axis
        /// x for a vertical guide, y for a horizontal one.
        public var position: CGFloat
        public init(axis: Axis, position: CGFloat) { self.axis = axis; self.position = position }
    }

    public struct Result: Equatable, Sendable {
        public var rect: CGRect
        public var guides: [Guide]
    }

    /// Threshold in canvas points for a view zoom.
    public static func canvasThreshold(zoom: Double) -> CGFloat {
        screenThreshold / CGFloat(max(zoom, 0.01))
    }

    /// Lines to stick to: monitor edges first, then every other tile's edges.
    public static func lines(monitor: CGRect, others: [CGRect]) -> (x: [CGFloat], y: [CGFloat]) {
        ([monitor.minX, monitor.maxX] + others.flatMap { [$0.minX, $0.maxX] },
         [monitor.minY, monitor.maxY] + others.flatMap { [$0.minY, $0.maxY] })
    }

    /// Snaps a moved rect (size kept). Both its edges per axis are tried; the closest line within `threshold` wins.
    public static func snapMove(_ rect: CGRect, monitor: CGRect, others: [CGRect], threshold: CGFloat) -> Result {
        guard threshold > 0 else { return Result(rect: rect, guides: []) }
        let l = lines(monitor: monitor, others: others)
        var out = rect
        var guides: [Guide] = []
        if let hit = best(rect.minX, rect.maxX, l.x, threshold) {
            out.origin.x += hit.shift
            guides.append(Guide(axis: .vertical, position: hit.line))
        }
        if let hit = best(rect.minY, rect.maxY, l.y, threshold) {
            out.origin.y += hit.shift
            guides.append(Guide(axis: .horizontal, position: hit.line))
        }
        return Result(rect: MapSnapping.clamp(out, into: monitor), guides: guides)
    }

    /// Snaps the moving edges of a resized rect. Fixed edges and `minSize` are kept.
    public static func snapResize(_ rect: CGRect, handle: ResizeHandle, monitor: CGRect, others: [CGRect],
                                  threshold: CGFloat, minSize: CGSize) -> Result {
        guard threshold > 0 else { return Result(rect: rect, guides: []) }
        let l = lines(monitor: monitor, others: others)
        var guides: [Guide] = []
        func hit(_ v: CGFloat, _ lines: [CGFloat]) -> CGFloat? {
            lines.filter { abs($0 - v) <= threshold }.min { abs($0 - v) < abs($1 - v) }
        }
        var probe = rect
        if handle.movesLeft, let x = hit(rect.minX, l.x) { guides.append(Guide(axis: .vertical, position: x)); probe = CGRect(x: x, y: probe.minY, width: probe.maxX - x, height: probe.height) }
        if handle.movesRight, let x = hit(rect.maxX, l.x) { guides.append(Guide(axis: .vertical, position: x)); probe = CGRect(x: probe.minX, y: probe.minY, width: x - probe.minX, height: probe.height) }
        if handle.movesTop, let y = hit(rect.minY, l.y) { guides.append(Guide(axis: .horizontal, position: y)); probe = CGRect(x: probe.minX, y: y, width: probe.width, height: probe.maxY - y) }
        if handle.movesBottom, let y = hit(rect.maxY, l.y) { guides.append(Guide(axis: .horizontal, position: y)); probe = CGRect(x: probe.minX, y: probe.minY, width: probe.width, height: y - probe.minY) }
        guard probe.width >= minSize.width, probe.height >= minSize.height else { return Result(rect: rect, guides: []) }
        return Result(rect: probe.intersection(monitor), guides: guides)
    }

    /// Guides for the lines `rect`'s edges currently sit on (within a hair), used after other snapping.
    public static func guides(for rect: CGRect, monitor: CGRect, others: [CGRect], tolerance: CGFloat = 0.5) -> [Guide] {
        let l = lines(monitor: monitor, others: others)
        var out: [Guide] = []
        for x in [rect.minX, rect.maxX] where l.x.contains(where: { abs($0 - x) <= tolerance }) { out.append(Guide(axis: .vertical, position: x)) }
        for y in [rect.minY, rect.maxY] where l.y.contains(where: { abs($0 - y) <= tolerance }) { out.append(Guide(axis: .horizontal, position: y)) }
        return out
    }

    private static func best(_ low: CGFloat, _ high: CGFloat, _ lines: [CGFloat], _ threshold: CGFloat)
        -> (shift: CGFloat, line: CGFloat)? {
        var found: (shift: CGFloat, line: CGFloat)?
        for line in lines {
            for v in [low, high] {
                let d = line - v
                if abs(d) <= threshold, found == nil || abs(d) < abs(found!.shift) { found = (d, line) }
            }
        }
        return found
    }
}
