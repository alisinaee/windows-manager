import CoreGraphics
import Foundation

// Bookkeeping for the snap gesture when Accessibility work runs off the main thread (phase P6.19).
// Every press and release starts a new gesture id. Results that come back for an older id (the gesture
// ended, or another press started) are dropped, and at most one window-frame read per gesture is in flight.
// Pure value type: no AppKit, no Accessibility.

public struct SnapGestureClock: Equatable, Sendable {
    /// Id of the gesture in progress (or the last one that ended).
    public private(set) var current: UInt64 = 0
    /// Gesture id of the frame read in flight, if any.
    public private(set) var frameReadInFlight: UInt64?

    public init() {}

    /// Starts a new gesture (call on every press and release). Returns its id.
    @discardableResult
    public mutating func advance() -> UInt64 {
        current &+= 1
        return current
    }

    /// True when a result tagged with `id` still belongs to the gesture in progress.
    public func isCurrent(_ id: UInt64) -> Bool { id == current }

    /// Asks whether a window-frame read should start for gesture `id`. Returns false when the gesture is not
    /// current or a read for it is already in flight; otherwise marks the read as in flight and returns true.
    public mutating func beginFrameRead(for id: UInt64) -> Bool {
        guard id == current, frameReadInFlight != id else { return false }
        frameReadInFlight = id
        return true
    }

    /// Call when a frame read tagged `id` has returned (whether or not its value is used).
    public mutating func finishFrameRead(for id: UInt64) {
        if frameReadInFlight == id { frameReadInFlight = nil }
    }

    /// True once the pointer has travelled at least `minimumDistance` points from the press point.
    public static func passedDragThreshold(from press: CGPoint, to point: CGPoint, minimumDistance: Double) -> Bool {
        hypot(point.x - press.x, point.y - press.y) >= CGFloat(minimumDistance)
    }
}
