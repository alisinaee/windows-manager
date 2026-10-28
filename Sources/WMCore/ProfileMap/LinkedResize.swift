import CoreGraphics
import Foundation

// Linked resize and overflow lock (G5). Pure value math on canvas rects (real screen points; y grows down).
// Linked resize: dragging an edge that touches a neighbour also moves the neighbour's matching edge, so no
// gap or overlap appears (like macOS Split View). Overlap lock: tiles may not overlap or leave the monitor.

public enum LinkedResize {
    /// Edges closer than this count as shared, canvas points.
    public static let tolerance: CGFloat = 2

    public struct Neighbour: Equatable, Sendable {
        public var id: UUID
        public var rect: CGRect
        public init(id: UUID, rect: CGRect) { self.id = id; self.rect = rect }
    }

    public struct Result: Equatable, Sendable {
        public var rect: CGRect
        /// New rects of the neighbours that changed.
        public var neighbours: [UUID: CGRect]
    }

    /// Neighbours whose facing edge touches the given edge of `rect` (and that overlap it along the edge).
    public static func sharedEdge(of rect: CGRect, side: Side, among neighbours: [Neighbour],
                                  tolerance: CGFloat = tolerance) -> [Neighbour] {
        neighbours.filter { n in
            switch side {
            case .left: return abs(n.rect.maxX - rect.minX) <= tolerance && spanOverlap(n.rect.minY, n.rect.maxY, rect.minY, rect.maxY)
            case .right: return abs(n.rect.minX - rect.maxX) <= tolerance && spanOverlap(n.rect.minY, n.rect.maxY, rect.minY, rect.maxY)
            case .top: return abs(n.rect.maxY - rect.minY) <= tolerance && spanOverlap(n.rect.minX, n.rect.maxX, rect.minX, rect.maxX)
            case .bottom: return abs(n.rect.minY - rect.maxY) <= tolerance && spanOverlap(n.rect.minX, n.rect.maxX, rect.minX, rect.maxX)
            }
        }
    }

    public enum Side: Sendable { case left, right, top, bottom }

    /// `proposed` is the dragged tile after a resize from `start` with `handle`. Returns it, with the moving edges
    /// held back so each linked neighbour keeps `minSize`, and the neighbours' new rects.
    public static func apply(start: CGRect, proposed: CGRect, handle: ResizeHandle, neighbours: [Neighbour],
                             minSize: CGSize, tolerance: CGFloat = tolerance) -> Result {
        var rect = proposed
        var links: [(side: Side, list: [Neighbour])] = []
        if handle.movesLeft { links.append((.left, sharedEdge(of: start, side: .left, among: neighbours, tolerance: tolerance))) }
        if handle.movesRight { links.append((.right, sharedEdge(of: start, side: .right, among: neighbours, tolerance: tolerance))) }
        if handle.movesTop { links.append((.top, sharedEdge(of: start, side: .top, among: neighbours, tolerance: tolerance))) }
        if handle.movesBottom { links.append((.bottom, sharedEdge(of: start, side: .bottom, among: neighbours, tolerance: tolerance))) }

        // Hold the moving edge back so the neighbour stays at least minSize.
        for (side, list) in links {
            switch side {
            case .left: if let lo = list.map({ $0.rect.minX + minSize.width }).max() { rect = setEdge(rect, .left, max(rect.minX, lo)) }
            case .right: if let hi = list.map({ $0.rect.maxX - minSize.width }).min() { rect = setEdge(rect, .right, min(rect.maxX, hi)) }
            case .top: if let lo = list.map({ $0.rect.minY + minSize.height }).max() { rect = setEdge(rect, .top, max(rect.minY, lo)) }
            case .bottom: if let hi = list.map({ $0.rect.maxY - minSize.height }).min() { rect = setEdge(rect, .bottom, min(rect.maxY, hi)) }
            }
        }
        var out: [UUID: CGRect] = [:]
        for (side, list) in links {
            for n in list {
                var r = out[n.id] ?? n.rect
                switch side {
                case .left: r = setEdge(r, .right, rect.minX)
                case .right: r = setEdge(r, .left, rect.maxX)
                case .top: r = setEdge(r, .bottom, rect.minY)
                case .bottom: r = setEdge(r, .top, rect.maxY)
                }
                out[n.id] = r
            }
        }
        return Result(rect: rect, neighbours: out.filter { entry in entry.value != neighbours.first(where: { $0.id == entry.key })?.rect })
    }

    static func setEdge(_ r: CGRect, _ side: Side, _ v: CGFloat) -> CGRect {
        switch side {
        case .left: return CGRect(x: v, y: r.minY, width: r.maxX - v, height: r.height)
        case .right: return CGRect(x: r.minX, y: r.minY, width: v - r.minX, height: r.height)
        case .top: return CGRect(x: r.minX, y: v, width: r.width, height: r.maxY - v)
        case .bottom: return CGRect(x: r.minX, y: r.minY, width: r.width, height: v - r.minY)
        }
    }

    private static func spanOverlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> Bool {
        min(a1, b1) - max(a0, b0) > 0.5
    }
}

public enum OverlapLock {
    /// Rects overlap by more than a hair (touching edges do not count).
    public static func overlaps(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        min(a.maxX, b.maxX) - max(a.minX, b.minX) > tolerance && min(a.maxY, b.maxY) - max(a.minY, b.minY) > tolerance
    }

    /// A moved rect (size kept) pushed inside `monitor` and out of every other tile by the smallest shift.
    /// When no free spot is found it returns `fallback`.
    public static func constrainMove(_ rect: CGRect, monitor: CGRect, others: [CGRect], fallback: CGRect) -> CGRect {
        func inside(_ r: CGRect) -> CGRect {
            CGRect(x: min(max(r.minX, monitor.minX), max(monitor.maxX - r.width, monitor.minX)),
                   y: min(max(r.minY, monitor.minY), max(monitor.maxY - r.height, monitor.minY)),
                   width: r.width, height: r.height)
        }
        var r = inside(rect)
        for _ in 0..<8 {
            guard let o = others.first(where: { overlaps(r, $0) }) else { return r }
            let moves = [CGPoint(x: o.minX - r.width, y: r.minY), CGPoint(x: o.maxX, y: r.minY),
                         CGPoint(x: r.minX, y: o.minY - r.height), CGPoint(x: r.minX, y: o.maxY)]
            let fits = moves.map { CGRect(origin: $0, size: r.size) }
                .filter { monitor.insetBy(dx: -0.01, dy: -0.01).contains($0) }
            guard let best = fits.min(by: { dist($0, r) < dist($1, r) }) else { return fallback }
            r = best
        }
        return others.contains { overlaps(r, $0) } ? fallback : r
    }

    /// A resized rect with its moving edges held inside `monitor` and against the tiles in their way.
    /// Returns `start` when the result would be smaller than `minSize`.
    public static func constrainResize(_ rect: CGRect, start: CGRect, handle: ResizeHandle, monitor: CGRect,
                                       others: [CGRect], minSize: CGSize) -> CGRect {
        var l = rect.minX, r = rect.maxX, t = rect.minY, b = rect.maxY
        if handle.movesLeft { l = max(l, monitor.minX) }
        if handle.movesRight { r = min(r, monitor.maxX) }
        if handle.movesTop { t = max(t, monitor.minY) }
        if handle.movesBottom { b = min(b, monitor.maxY) }
        for _ in 0..<2 {
            for o in others {
                let box = CGRect(x: l, y: t, width: r - l, height: b - t)
                guard overlaps(box, o) else { continue }
                // Pull back the moving edge facing the tile that was beside the start rect.
                if handle.movesRight, o.minX >= start.maxX - 0.5 { r = min(r, o.minX) }
                else if handle.movesLeft, o.maxX <= start.minX + 0.5 { l = max(l, o.maxX) }
                else if handle.movesBottom, o.minY >= start.maxY - 0.5 { b = min(b, o.minY) }
                else if handle.movesTop, o.maxY <= start.minY + 0.5 { t = max(t, o.maxY) }
            }
        }
        let out = CGRect(x: l, y: t, width: r - l, height: b - t)
        if out.width < minSize.width || out.height < minSize.height { return start }
        return others.contains { overlaps(out, $0) } && !others.contains { overlaps(start, $0) } ? start : out
    }

    private static func dist(_ a: CGRect, _ b: CGRect) -> CGFloat { abs(a.minX - b.minX) + abs(a.minY - b.minY) }
}
