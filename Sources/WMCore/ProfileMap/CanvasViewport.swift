import CoreGraphics
import Foundation

/// Pure pan/zoom math for the Studio map canvas. A content point `c` shows at screen point `c * zoom + offset`
/// (both measured from the top-left of the viewport), so panning is just `offset` and zooming rescales around a point.
public struct CanvasViewport: Equatable, Sendable {
    /// The zoom limits: 10% to 400% of the fitted map.
    public static let zoomRange: ClosedRange<Double> = 0.1...4.0
    /// How much of the content must stay inside the viewport when panning, so it can never be lost completely.
    public static let panMargin: CGFloat = 80

    public var zoom: Double
    public var offset: CGPoint

    public init(zoom: Double = 1, offset: CGPoint = .zero) {
        self.zoom = Self.clamp(zoom)
        self.offset = offset
    }

    public static func clamp(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// The viewport after zooming to `newZoom` (clamped) while the content point under `anchor` (a viewport point) stays put.
    public func zoomed(to newZoom: Double, around anchor: CGPoint) -> CanvasViewport {
        let target = Self.clamp(newZoom)
        let ratio = CGFloat(target / zoom)
        return CanvasViewport(zoom: target, offset: CGPoint(x: anchor.x - (anchor.x - offset.x) * ratio,
                                                            y: anchor.y - (anchor.y - offset.y) * ratio))
    }

    /// Moves the content by `delta` screen points.
    public func panned(by delta: CGSize) -> CanvasViewport {
        CanvasViewport(zoom: zoom, offset: CGPoint(x: offset.x + delta.width, y: offset.y + delta.height))
    }

    /// Keeps at least `margin` points of the content (`contentSize` at the current zoom) inside `viewport`,
    /// so the content may be panned fully off-screen except for that margin.
    public func clamped(content: CGSize, viewport: CGSize, margin: CGFloat = CanvasViewport.panMargin) -> CanvasViewport {
        func axis(_ value: CGFloat, _ contentLength: CGFloat, _ viewLength: CGFloat) -> CGFloat {
            let m = min(margin, contentLength * CGFloat(zoom), viewLength)
            return min(max(value, m - contentLength * CGFloat(zoom)), viewLength - m)
        }
        return CanvasViewport(zoom: zoom, offset: CGPoint(x: axis(offset.x, content.width, viewport.width),
                                                          y: axis(offset.y, content.height, viewport.height)))
    }

    /// The viewport that shows `rect` (content coordinates) centred, with `padding` around it.
    /// The zoom is the largest that fits, capped at `maxZoom` and at the zoom range.
    public static func fitting(_ rect: CGRect, in viewport: CGSize, padding: CGFloat = 24, maxZoom: Double = zoomRange.upperBound) -> CanvasViewport {
        guard rect.width > 0, rect.height > 0, viewport.width > 0, viewport.height > 0 else { return CanvasViewport() }
        let availableW = max(viewport.width - 2 * padding, 1)
        let availableH = max(viewport.height - 2 * padding, 1)
        let zoom = min(clamp(Double(min(availableW / rect.width, availableH / rect.height))), maxZoom)
        let z = CGFloat(zoom)
        return CanvasViewport(zoom: zoom, offset: CGPoint(x: viewport.width / 2 - rect.midX * z,
                                                          y: viewport.height / 2 - rect.midY * z))
    }

    /// The content point shown at viewport point `screen`.
    public func contentPoint(atScreen screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - offset.x) / CGFloat(zoom), y: (screen.y - offset.y) / CGFloat(zoom))
    }
}
