import Foundation

// Undo/redo for the Profile Studio Builder (plan B2 "Undo"): a stack of whole draft values.
// Consecutive edits of the same kind that come within `coalesceWindow` seconds of each other (nudging a
// window with the arrow keys, typing in a percentage field) share one undo entry.

/// A value-type undo/redo history. `State` is normally a `Profile`.
public struct EditHistory<State> {
    public static var defaultCap: Int { 100 }
    public static var defaultCoalesceWindow: TimeInterval { 0.5 }

    /// The value being edited.
    public private(set) var current: State
    /// Older values, oldest first. Never longer than `cap`.
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    public let cap: Int
    public let coalesceWindow: TimeInterval
    private let clock: () -> TimeInterval
    private var lastKind: String?
    private var lastTime: TimeInterval = 0

    /// `clock` returns seconds on any steady scale; tests pass their own.
    public init(initial: State, cap: Int = EditHistory.defaultCap,
                coalesceWindow: TimeInterval = EditHistory.defaultCoalesceWindow,
                clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.current = initial
        self.cap = max(1, cap)
        self.coalesceWindow = coalesceWindow
        self.clock = clock
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoCount: Int { undoStack.count }
    public var redoCount: Int { redoStack.count }

    /// Makes `newState` the current value. With a `kind`, an edit of the same kind within the coalesce window
    /// of the previous edit replaces the current value without a new undo entry. Clears the redo stack.
    public mutating func record(_ newState: State, kind: String? = nil) {
        let now = clock()
        redoStack.removeAll()
        if let kind, kind == lastKind, now - lastTime <= coalesceWindow, !undoStack.isEmpty {
            current = newState
            lastTime = now
            return
        }
        undoStack.append(current)
        if undoStack.count > cap { undoStack.removeFirst(undoStack.count - cap) }
        current = newState
        lastKind = kind
        lastTime = now
    }

    /// Goes back one entry. Returns false when there is nothing to undo.
    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(current)
        current = previous
        lastKind = nil
        return true
    }

    /// Goes forward one entry. Returns false when there is nothing to redo.
    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(current)
        current = next
        lastKind = nil
        return true
    }

    /// Replaces the current value without an undo entry (a live refresh from the desktop, P6.67). The undo and redo
    /// stacks are kept.
    public mutating func replaceCurrent(_ state: State) {
        current = state
    }

    /// Starts over with `state` and no history (after a save, for example).
    public mutating func reset(to state: State) {
        current = state
        undoStack.removeAll()
        redoStack.removeAll()
        lastKind = nil
    }
}
