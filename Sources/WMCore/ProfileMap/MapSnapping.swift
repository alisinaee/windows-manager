import CoreGraphics
import Foundation

// Snapping and default placement for window tiles dragged in the builder map (PM7).
// Pure value math on canvas rects: no AppKit, no SwiftUI.
//
// Rules:
// - Every rect is in canvas points. `monitorContent` is the monitor's visible part (`ProfileMapLayout.Monitor.contentRect`).
// - A rect is first clamped to the minimum size (80 x 60, or the monitor size when it is smaller).
// - If the rect's center is inside a zone, the rect becomes that zone's rect (the smallest zone wins) and the zone name is reported.
//   Zone snapping reports no snapped edges.
// - Otherwise the rect is moved (never resized) so one of its edges lines up with a monitor edge or with another
//   window's edge, when that is within `SnapOptions.threshold`. The closest line wins; monitor edges win ties.
// - `SnapOptions.disabled` (Option held while dragging) turns off zone and edge snapping. Clamping still applies.
// - Every result is clamped inside `monitorContent`.
//
// Relative frames (`Profile` `WindowSnapshot.relativeFrame`) are fractions of the monitor's visible frame, so
// `relativeFrame(of:in:)` and `canvasRect(forRelative:in:)` take the same `monitorContent` rect. The y axis
// increases the same way as canvas y, like `ProfileMapLayout.windowRect` and `ProfileCapture.relativeFrame`.

public enum MapSnapping {
    /// Smallest window width in canvas points.
    public static let minimumWidth: CGFloat = 80
    /// Smallest window height in canvas points.
    public static let minimumHeight: CGFloat = 60
    /// Default edge snap distance in canvas points.
    public static let defaultThreshold: CGFloat = 8
    /// Step of the cascade for default placement, in canvas points.
    public static let cascadeOffset: CGFloat = 24

    /// Which edges of the snapped rect lined up with a target.
    public enum Edge: Hashable, CaseIterable, Sendable {
        case left, right, top, bottom
    }

    /// Snapping settings for one drag.
    public struct SnapOptions: Equatable, Sendable {
        /// True while Option is held: no zone or edge snapping.
        public var disabled: Bool
        /// Edge snap distance in canvas points. Zero or less turns edge snapping off.
        public var threshold: CGFloat

        public init(disabled: Bool = false, threshold: CGFloat = MapSnapping.defaultThreshold) {
            self.disabled = disabled
            self.threshold = threshold
        }
    }

    /// The result of snapping one rect.
    public struct SnapResult: Equatable, Sendable {
        /// The rect to draw and store, canvas points, inside the monitor content.
        public var rect: CGRect
        /// The zone the rect was snapped to, when its center was inside a zone.
        public var zoneName: String?
        /// The edges that lined up with a monitor or window edge. Empty for zone snapping and for no snap.
        public var snappedEdges: Set<Edge>

        public init(rect: CGRect, zoneName: String?, snappedEdges: Set<Edge>) {
            self.rect = rect
            self.zoneName = zoneName
            self.snappedEdges = snappedEdges
        }
    }

    // MARK: Snapping

    /// Snaps a dragged window rect.
    /// - Parameters:
    ///   - rect: the rect under the pointer, canvas points.
    ///   - monitorContent: the monitor's visible rect, canvas points.
    ///   - zones: the Layout zones of this monitor, as canvas rects. Empty when no Layout is chosen.
    ///   - edges: the other windows' rects on the same Desktop (the dragged window excluded).
    ///   - option: snapping settings.
    public static func snap(rect: CGRect, in monitorContent: CGRect, zones: [(name: String, rect: CGRect)],
                            edges: [CGRect], option: SnapOptions = SnapOptions()) -> SnapResult {
        let sized = clampSize(rect, in: monitorContent)
        if option.disabled {
            return SnapResult(rect: clamp(sized, into: monitorContent), zoneName: nil, snappedEdges: [])
        }

        // Zone: the smallest zone that holds the center wins.
        let center = CGPoint(x: sized.midX, y: sized.midY)
        let holding = zones.filter { $0.rect.contains(center) }
        if let zone = holding.min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
            return SnapResult(rect: clamp(zone.rect, into: monitorContent), zoneName: zone.name, snappedEdges: [])
        }

        var snapped = sized
        var snappedEdges: Set<Edge> = []
        if option.threshold > 0 {
            // Monitor edges first, so they win ties against window edges.
            let xLines = [monitorContent.minX, monitorContent.maxX] + edges.flatMap { [$0.minX, $0.maxX] }
            let yLines = [monitorContent.minY, monitorContent.maxY] + edges.flatMap { [$0.minY, $0.maxY] }
            if let best = bestShift(low: sized.minX, high: sized.maxX, lines: xLines, threshold: option.threshold) {
                snapped.origin.x += best.shift
                snappedEdges.insert(best.low ? .left : .right)
            }
            if let best = bestShift(low: sized.minY, high: sized.maxY, lines: yLines, threshold: option.threshold) {
                snapped.origin.y += best.shift
                snappedEdges.insert(best.low ? .bottom : .top)
            }
        }
        return SnapResult(rect: clamp(snapped, into: monitorContent), zoneName: nil, snappedEdges: snappedEdges)
    }

    /// The smallest shift that puts one of the two edges (`low`, `high`) on a line, within `threshold`.
    private static func bestShift(low: CGFloat, high: CGFloat, lines: [CGFloat],
                                  threshold: CGFloat) -> (shift: CGFloat, low: Bool)? {
        var best: (shift: CGFloat, low: Bool)?
        for line in lines {
            for (value, isLow) in [(low, true), (high, false)] {
                let delta = line - value
                guard abs(delta) <= threshold else { continue }
                if best == nil || abs(delta) < abs(best!.shift) {
                    best = (delta, isLow)
                }
            }
        }
        return best
    }

    // MARK: Default placement

    /// Where a new window goes on a monitor: 50% x 70% of the content, centered for the first window, then
    /// cascaded by `cascadeOffset` per window (+x, +y). The cascade wraps before the window would leave the monitor.
    /// - Parameters:
    ///   - monitorContent: the monitor's visible rect, canvas points.
    ///   - index: how many windows are already on this Desktop (0 = first).
    public static func defaultPlacement(for monitorContent: CGRect, index: Int) -> CGRect {
        let size = clampSize(CGRect(x: 0, y: 0, width: monitorContent.width * 0.5,
                                    height: monitorContent.height * 0.7), in: monitorContent).size
        let base = CGRect(x: monitorContent.midX - size.width / 2, y: monitorContent.midY - size.height / 2,
                          width: size.width, height: size.height)
        let room = max(min(monitorContent.width - size.width, monitorContent.height - size.height), 0)
        let steps = Int(room / cascadeOffset) + 1
        let step = CGFloat(max(index, 0) % steps) * cascadeOffset
        return clamp(base.offsetBy(dx: step, dy: step), into: monitorContent)
    }

    // MARK: Clamping

    /// Clamps `rect` inside `container`: size first (at least 80 x 60, at most the container), then position.
    public static func clamp(_ rect: CGRect, into container: CGRect) -> CGRect {
        let sized = clampSize(rect, in: container)
        let x = min(max(sized.minX, container.minX), container.maxX - sized.width)
        let y = min(max(sized.minY, container.minY), container.maxY - sized.height)
        return CGRect(x: x, y: y, width: sized.width, height: sized.height)
    }

    /// Raises the size to the minimum (80 x 60) and lowers it to the container size. The origin is kept.
    private static func clampSize(_ rect: CGRect, in container: CGRect) -> CGRect {
        let width = min(max(rect.width, minimumWidth), max(container.width, 0))
        let height = min(max(rect.height, minimumHeight), max(container.height, 0))
        return CGRect(x: rect.minX, y: rect.minY, width: width, height: height)
    }

    // MARK: Relative frames

    /// Canvas rect as fractions of the monitor content, the profile's `relativeFrame` convention.
    /// A degenerate content gives the full frame (0, 0, 1, 1).
    public static func relativeFrame(of rect: CGRect, in monitorContent: CGRect) -> CGRect {
        guard monitorContent.width > 0, monitorContent.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: (rect.minX - monitorContent.minX) / monitorContent.width,
                      y: (rect.minY - monitorContent.minY) / monitorContent.height,
                      width: rect.width / monitorContent.width,
                      height: rect.height / monitorContent.height)
    }

    /// Inverse of `relativeFrame(of:in:)`: a profile `relativeFrame` as a canvas rect in the monitor content.
    public static func canvasRect(forRelative relative: CGRect, in monitorContent: CGRect) -> CGRect {
        CGRect(x: monitorContent.minX + relative.minX * monitorContent.width,
               y: monitorContent.minY + relative.minY * monitorContent.height,
               width: relative.width * monitorContent.width,
               height: relative.height * monitorContent.height)
    }
}
