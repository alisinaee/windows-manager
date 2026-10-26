import Foundation

/// Holds control commands that arrived before the app state could handle them, in arrival order.
/// Pure value logic: the app decides when to drain it.
public struct ControlCommandQueue: Equatable, Sendable {
    public private(set) var pending: [ControlCommand] = []

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    public mutating func enqueue(_ command: ControlCommand) {
        pending.append(command)
    }

    /// Returns every queued command in arrival order and empties the queue, so each runs once.
    public mutating func drain() -> [ControlCommand] {
        let out = pending
        pending.removeAll()
        return out
    }
}
