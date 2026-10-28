import CoreGraphics
import Foundation

/// What a window refuses when it is resized: a fixed width and/or height, and minimum / maximum sizes.
/// Saved on a profile window as an optional field; a window without it is treated as unknown (resizable).
public struct WindowResizeLimits: Codable, Hashable, Sendable {
    public var fixedWidth: Bool
    public var fixedHeight: Bool
    public var canMove: Bool
    public var minSize: CGSize?
    public var maxSize: CGSize?

    public init(fixedWidth: Bool = false, fixedHeight: Bool = false, canMove: Bool = true,
                minSize: CGSize? = nil, maxSize: CGSize? = nil) {
        self.fixedWidth = fixedWidth
        self.fixedHeight = fixedHeight
        self.canMove = canMove
        self.minSize = minSize
        self.maxSize = maxSize
    }

    private enum CodingKeys: String, CodingKey { case fixedWidth, fixedHeight, canMove, minSize, maxSize }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fixedWidth = try c.decodeIfPresent(Bool.self, forKey: .fixedWidth) ?? false
        fixedHeight = try c.decodeIfPresent(Bool.self, forKey: .fixedHeight) ?? false
        canMove = try c.decodeIfPresent(Bool.self, forKey: .canMove) ?? true
        minSize = try c.decodeIfPresent(CGSize.self, forKey: .minSize)
        maxSize = try c.decodeIfPresent(CGSize.self, forKey: .maxSize)
    }

    /// True when any restriction is known.
    public var hasRestrictions: Bool {
        fixedWidth || fixedHeight || !canMove || minSize != nil || maxSize != nil
    }

    /// Message for tooltips; nil when nothing is fixed.
    public var fixedMessage: String? {
        switch (fixedWidth, fixedHeight) {
        case (true, true): return "This app does not allow changing width or height"
        case (true, false): return "This app does not allow changing width"
        case (false, true): return "This app does not allow changing height"
        default: return nil
        }
    }

    // MARK: Pure decisions

    /// Limits from non-moving reads. Only an unsettable size is conclusive; a disabled zoom / full-screen button
    /// or a missing grow area alone is a hint (many apps disable those but still resize), so it never fixes a size.
    public static func fromAttributes(sizeSettable: Bool, positionSettable: Bool) -> WindowResizeLimits {
        WindowResizeLimits(fixedWidth: !sizeSettable, fixedHeight: !sizeSettable, canMove: positionSettable)
    }

    /// One axis of a probe: the extent before, after asking for +delta, and after asking for -delta.
    public struct AxisProbe: Equatable, Sendable {
        public var original: CGFloat
        public var afterGrow: CGFloat
        public var afterShrink: CGFloat
        public init(original: CGFloat, afterGrow: CGFloat, afterShrink: CGFloat) {
            self.original = original
            self.afterGrow = afterGrow
            self.afterShrink = afterShrink
        }
    }

    /// What a probe of one axis says: fixed, or bounded (the window sits at its max / min), or free.
    public struct AxisResult: Equatable, Sendable {
        public var fixed: Bool
        public var min: CGFloat?
        public var max: CGFloat?
    }

    public static func axisResult(_ p: AxisProbe, tolerance: CGFloat = 1) -> AxisResult {
        let grew = p.afterGrow - p.original > tolerance
        let shrank = p.original - p.afterShrink > tolerance
        switch (grew, shrank) {
        case (false, false): return AxisResult(fixed: true, min: nil, max: nil)
        case (false, true): return AxisResult(fixed: false, min: nil, max: p.original)
        case (true, false): return AxisResult(fixed: false, min: p.original, max: nil)
        case (true, true): return AxisResult(fixed: false, min: nil, max: nil)
        }
    }

    /// Limits from probe readings, merged over the attribute-based limits.
    public static func fromProbe(width: AxisProbe, height: AxisProbe, base: WindowResizeLimits = WindowResizeLimits(),
                                 tolerance: CGFloat = 1) -> WindowResizeLimits {
        let w = axisResult(width, tolerance: tolerance), h = axisResult(height, tolerance: tolerance)
        var out = base
        out.fixedWidth = w.fixed
        out.fixedHeight = h.fixed
        let minW = w.min, minH = h.min, maxW = w.max, maxH = h.max
        if minW != nil || minH != nil { out.minSize = CGSize(width: minW ?? 0, height: minH ?? 0) }
        if maxW != nil || maxH != nil {
            out.maxSize = CGSize(width: maxW ?? .greatestFiniteMagnitude, height: maxH ?? .greatestFiniteMagnitude)
        }
        return out
    }

    /// `frame` changed so the window would accept it. A fixed axis keeps the width / height of `current`
    /// (the edge that did not move stays put); other axes are held inside min / max. The origin follows
    /// the clamped size only when the right / bottom edge was the one that stayed still.
    public func clamp(_ frame: CGRect, current: CGRect) -> CGRect {
        var out = frame
        func axis(_ origin: CGFloat, _ size: CGFloat, cur0: CGFloat, curSize: CGFloat, fixed: Bool,
                  lo: CGFloat?, hi: CGFloat?) -> (CGFloat, CGFloat) {
            var s = size
            if fixed { s = curSize } else {
                if let lo, lo > 0 { s = Swift.max(s, lo) }
                if let hi, hi < .greatestFiniteMagnitude / 2 { s = Swift.min(s, hi) }
            }
            guard abs(s - size) > 0.001 else { return (origin, size) }
            // The far edge stayed still while the near edge moved (resize from the left / top): keep the far edge.
            var o = origin
            if abs((origin + size) - (cur0 + curSize)) < 0.5, abs(origin - cur0) > 0.5 { o = cur0 + curSize - s }
            return (o, s)
        }
        let x = axis(frame.minX, frame.width, cur0: current.minX, curSize: current.width, fixed: fixedWidth,
                     lo: minSize?.width, hi: maxSize?.width)
        let y = axis(frame.minY, frame.height, cur0: current.minY, curSize: current.height, fixed: fixedHeight,
                     lo: minSize?.height, hi: maxSize?.height)
        out = CGRect(x: x.0, y: y.0, width: x.1, height: y.1)
        return out
    }

    /// Size-only clamp for an area that resized without a reference frame.
    public func clamp(_ frame: CGRect) -> CGRect { clamp(frame, current: frame) }
}

// MARK: - Detection (Accessibility)

public enum WindowResizeDetector {
    /// Non-probing read: settable flags only. Never moves or resizes a window.
    public static func read(_ window: AXElement) -> WindowResizeLimits {
        WindowResizeLimits.fromAttributes(sizeSettable: window.isSettable("AXSize"),
                                          positionSettable: window.isSettable("AXPosition"))
    }

    /// Hints from the zoom / full-screen buttons and the grow area, for `wm windows limits`.
    public static func hints(_ window: AXElement) -> [String] {
        var out: [String] = []
        if let zoom = window.element("AXZoomButton"), zoom.bool("AXEnabled") == false { out.append("zoom button disabled") }
        if let fs = window.element("AXFullScreenButton"), fs.bool("AXEnabled") == false { out.append("full-screen button disabled") }
        if window.element("AXGrowArea") != nil { out.append("has grow area") }
        return out
    }

    /// Active probe: nudges the width and then the height by +/-`delta` and restores the original frame.
    /// Moves a real window, so callers must opt in (capture-time flag or `--probe --yes`).
    public static func probe(_ window: AXElement, delta: CGFloat = 8) -> WindowResizeLimits {
        let base = read(window)
        guard let original = frame(of: window) else { return base }
        func extent(_ horizontal: Bool) -> WindowResizeLimits.AxisProbe {
            let o = size(of: window) ?? original.size
            func try_(_ d: CGFloat) -> CGFloat {
                let want = horizontal ? CGSize(width: o.width + d, height: o.height) : CGSize(width: o.width, height: o.height + d)
                window.set("AXSize", want)
                let got = size(of: window) ?? o
                window.set("AXSize", o)
                return horizontal ? got.width : got.height
            }
            let grow = try_(delta), shrink = try_(-delta)
            return .init(original: horizontal ? o.width : o.height, afterGrow: grow, afterShrink: shrink)
        }
        guard base.fixedWidth == false || base.fixedHeight == false else { window.set("AXPosition", original.origin); return base }
        let w = extent(true), h = extent(false)
        // Restore the exact original frame.
        window.set("AXSize", original.size)
        window.set("AXPosition", original.origin)
        return WindowResizeLimits.fromProbe(width: w, height: h, base: base)
    }

    private static func size(of window: AXElement) -> CGSize? { window.sizeValue("AXSize") }
    private static func frame(of window: AXElement) -> CGRect? {
        guard let p = window.pointValue("AXPosition"), let s = size(of: window) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
