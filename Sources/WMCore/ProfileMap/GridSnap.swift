import CoreGraphics
import Foundation

// Grid overlay and grid snapping for window tiles in the builder map (G1, G2). Pure value math on canvas rects
// in real screen points (the canvas is not scaled; zoom is a view concern). A grid divides a monitor's
// visible content rect into `columns` x `rows` equal cells.

/// How many cells a monitor grid has.
public struct GridSpec: Equatable, Hashable, Codable, Sendable {
    public static let limits = 1...64

    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = min(max(columns, Self.limits.lowerBound), Self.limits.upperBound)
        self.rows = min(max(rows, Self.limits.lowerBound), Self.limits.upperBound)
    }

    public static let small = GridSpec(columns: 24, rows: 12)
    public static let medium = GridSpec(columns: 12, rows: 6)
    public static let large = GridSpec(columns: 6, rows: 3)

    /// The named presets, finest first.
    public static let presets: [(name: String, spec: GridSpec)] = [("Small", small), ("Medium", medium), ("Large", large)]

    /// The preset name for this spec, or "Custom".
    public var presetName: String { Self.presets.first { $0.spec == self }?.name ?? "Custom" }
}

public enum GridSnap {
    /// Vertical line x positions (columns + 1 of them) inside `content`.
    public static func xLines(_ spec: GridSpec, in content: CGRect) -> [CGFloat] {
        (0...spec.columns).map { content.minX + content.width * CGFloat($0) / CGFloat(spec.columns) }
    }

    /// Horizontal line y positions (rows + 1 of them) inside `content`.
    public static func yLines(_ spec: GridSpec, in content: CGRect) -> [CGFloat] {
        (0...spec.rows).map { content.minY + content.height * CGFloat($0) / CGFloat(spec.rows) }
    }

    /// The line nearest to `value`.
    public static func nearestLine(to value: CGFloat, in lines: [CGFloat]) -> CGFloat {
        lines.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    /// Moves `rect` (size kept) so its left or top edge, or its right or bottom edge, lands on a grid line,
    /// whichever needs the smaller shift per axis. The result stays inside `content`.
    public static func snapMove(_ rect: CGRect, spec: GridSpec, in content: CGRect) -> CGRect {
        let xs = xLines(spec, in: content), ys = yLines(spec, in: content)
        var out = rect
        out.origin.x += smallestShift(low: rect.minX, high: rect.maxX, lines: xs)
        out.origin.y += smallestShift(low: rect.minY, high: rect.maxY, lines: ys)
        return MapSnapping.clamp(out, into: content)
    }

    /// Snaps the moving edges of a resized rect to the nearest grid lines, keeping `minSize` and `content`.
    public static func snapResize(_ rect: CGRect, handle: ResizeHandle, spec: GridSpec, in content: CGRect,
                                  minSize: CGSize) -> CGRect {
        let snapped = ResizeHandles.snapMovingEdges(rect, handle: handle, xLines: xLines(spec, in: content),
                                                    yLines: yLines(spec, in: content),
                                                    threshold: .greatestFiniteMagnitude, minSize: minSize)
        return snapped.intersection(content)
    }

    private static func smallestShift(low: CGFloat, high: CGFloat, lines: [CGFloat]) -> CGFloat {
        let a = nearestLine(to: low, in: lines) - low
        let b = nearestLine(to: high, in: lines) - high
        return abs(a) <= abs(b) ? a : b
    }
}
