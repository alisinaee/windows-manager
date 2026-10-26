import CoreGraphics
import Foundation

// Resize handles of the selected window tile in the builder map (UI5). Pure value math on canvas rects:
// handle rects, hit testing, resizing from a handle with a minimum size, snapping the moving edges, and the
// keyboard nudge / resize on relative frames (fractions 0...1 of the monitor content).
// The y axis increases downward, like canvas y.

/// One of the 8 handles of a rect: 4 corners and 4 edge midpoints.
public enum ResizeHandle: CaseIterable, Hashable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    public var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    public var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    public var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    public var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    /// Spoken name, for accessibility.
    public var title: String {
        switch self {
        case .topLeft: return "top left corner"
        case .top: return "top edge"
        case .topRight: return "top right corner"
        case .right: return "right edge"
        case .bottomRight: return "bottom right corner"
        case .bottom: return "bottom edge"
        case .bottomLeft: return "bottom left corner"
        case .left: return "left edge"
        }
    }
}

public enum ResizeHandles {
    /// Side of a handle square in canvas points.
    public static let handleSize: CGFloat = 10

    /// The point a handle sits on.
    public static func center(of handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        let x = handle.movesLeft ? rect.minX : (handle.movesRight ? rect.maxX : rect.midX)
        let y = handle.movesTop ? rect.minY : (handle.movesBottom ? rect.maxY : rect.midY)
        return CGPoint(x: x, y: y)
    }

    /// The square of a handle, centered on its point.
    public static func handleRect(_ handle: ResizeHandle, in rect: CGRect, size: CGFloat = handleSize) -> CGRect {
        let c = center(of: handle, in: rect)
        return CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
    }

    /// The handle under `point`, or nil. Corners win over edges. On a small rect the handles would overlap,
    /// so the hit area of each handle shrinks to a third of the rect side at most.
    public static func hitTest(_ point: CGPoint, in rect: CGRect, size: CGFloat = handleSize) -> ResizeHandle? {
        let reachX = min(size / 2, max(rect.width / 3, 0))
        let reachY = min(size / 2, max(rect.height / 3, 0))
        let ordered = ResizeHandle.allCases.filter(\.isCorner) + ResizeHandle.allCases.filter { !$0.isCorner }
        for handle in ordered {
            let c = center(of: handle, in: rect)
            if abs(point.x - c.x) <= reachX, abs(point.y - c.y) <= reachY { return handle }
        }
        return nil
    }

    /// `rect` after dragging `handle` by `translation`. The edges opposite the handle stay put; the moving
    /// edges stay inside `bounds` (when given) and never get closer than `minSize` to the fixed ones.
    public static func resize(_ rect: CGRect, handle: ResizeHandle, by translation: CGSize,
                              minSize: CGSize, within bounds: CGRect? = nil) -> CGRect {
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        if handle.movesLeft { left += translation.width }
        if handle.movesRight { right += translation.width }
        if handle.movesTop { top += translation.height }
        if handle.movesBottom { bottom += translation.height }
        if let bounds {
            if handle.movesLeft { left = max(left, bounds.minX) }
            if handle.movesRight { right = min(right, bounds.maxX) }
            if handle.movesTop { top = max(top, bounds.minY) }
            if handle.movesBottom { bottom = min(bottom, bounds.maxY) }
        }
        return enforceMinimum(left: left, right: right, top: top, bottom: bottom, handle: handle, minSize: minSize)
    }

    /// Snaps the moving edges of `rect` to the nearest line within `threshold`. Fixed edges and the minimum
    /// size are kept. Lines are canvas coordinates (monitor edges, other windows' edges, zone edges).
    public static func snapMovingEdges(_ rect: CGRect, handle: ResizeHandle, xLines: [CGFloat], yLines: [CGFloat],
                                       threshold: CGFloat, minSize: CGSize) -> CGRect {
        guard threshold > 0 else { return rect }
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        if handle.movesLeft { left = nearest(left, in: xLines, threshold: threshold) }
        if handle.movesRight { right = nearest(right, in: xLines, threshold: threshold) }
        if handle.movesTop { top = nearest(top, in: yLines, threshold: threshold) }
        if handle.movesBottom { bottom = nearest(bottom, in: yLines, threshold: threshold) }
        return enforceMinimum(left: left, right: right, top: top, bottom: bottom, handle: handle, minSize: minSize)
    }

    // MARK: Relative frames (keyboard)

    /// Moves a relative frame by (`dx`, `dy`) fractions, keeping its size and staying inside 0...1.
    public static func nudge(relative: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        let x = min(max(relative.minX + dx, 0), max(1 - relative.width, 0))
        let y = min(max(relative.minY + dy, 0), max(1 - relative.height, 0))
        return CGRect(x: x, y: y, width: relative.width, height: relative.height)
    }

    /// Grows or shrinks a relative frame by (`dw`, `dh`) fractions, keeping its origin. The size stays at least
    /// `minSize` and inside 0...1.
    public static func resize(relative: CGRect, dw: CGFloat, dh: CGFloat, minSize: CGSize) -> CGRect {
        let width = min(max(relative.width + dw, minSize.width), max(1 - relative.minX, minSize.width))
        let height = min(max(relative.height + dh, minSize.height), max(1 - relative.minY, minSize.height))
        return CGRect(x: relative.minX, y: relative.minY, width: width, height: height)
    }

    // MARK: Helpers

    private static func nearest(_ value: CGFloat, in lines: [CGFloat], threshold: CGFloat) -> CGFloat {
        var best = value
        var bestDistance = threshold + 1
        for line in lines {
            let d = abs(line - value)
            if d <= threshold, d < bestDistance { best = line; bestDistance = d }
        }
        return best
    }

    private static func enforceMinimum(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat,
                                       handle: ResizeHandle, minSize: CGSize) -> CGRect {
        var left = left, right = right, top = top, bottom = bottom
        if handle.movesLeft { left = min(left, right - minSize.width) }
        if handle.movesRight { right = max(right, left + minSize.width) }
        if handle.movesTop { top = min(top, bottom - minSize.height) }
        if handle.movesBottom { bottom = max(bottom, top + minSize.height) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
