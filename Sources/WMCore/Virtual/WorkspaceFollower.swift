import Foundation

// Switching triggers for virtual workspaces (phase P5.3). Pure logic, no system calls:
// (a) WorkspaceFollower decides whether an app/window activation (Cmd+Tab, Dock click) should switch workspace;
// (b) WorkspaceSwitchCommand maps "switch to N / next / previous" to workspace ids, wrapping around.
// Registering the hotkeys themselves is not done here.

/// An app or window came to the front.
public struct WorkspaceActivationEvent: Equatable, Sendable {
    public var bundleID: String?
    public var windowID: UInt32?

    public init(bundleID: String?, windowID: UInt32? = nil) {
        self.bundleID = bundleID
        self.windowID = windowID
    }
}

/// Decides whether an activation means "go to another workspace".
public final class WorkspaceFollower {
    /// Events closer together than this (seconds) after the last accepted one are ignored.
    public var debounceInterval: TimeInterval
    /// Events this soon (seconds) after one of our own switches ended are ignored (they are its side effects).
    public var settleInterval: TimeInterval
    /// Set while a switch is running; every event is ignored then.
    public var isSwitching = false
    public var isEnabled = true

    private let clock: () -> TimeInterval
    private var lastAccepted: TimeInterval?
    private var lastSwitchEnded: TimeInterval?

    public init(debounceInterval: TimeInterval = 0.25, settleInterval: TimeInterval = 0.5,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.debounceInterval = debounceInterval
        self.settleInterval = settleInterval
        self.clock = clock
    }

    /// Call right after a switch finished (ours or a hotkey one), to swallow the activations it caused.
    public func switchDidEnd() {
        isSwitching = false
        lastSwitchEnded = clock()
    }

    /// The workspace to switch to, or nil to do nothing.
    public func targetWorkspace(for event: WorkspaceActivationEvent, model: WorkspaceModel) -> UUID? {
        guard isEnabled, !isSwitching else { return nil }
        let now = clock()
        if let ended = lastSwitchEnded, now - ended < settleInterval { return nil }
        if let last = lastAccepted, now - last < debounceInterval { return nil }

        guard let target = Self.owner(of: event, in: model) else { return nil }
        if target == model.activeWorkspaceID { return nil }
        lastAccepted = now
        return target
    }

    /// The workspace an activated app/window belongs to. The current workspace wins when it claims the
    /// event; otherwise the first workspace that does. Nil when none claims it.
    public static func owner(of event: WorkspaceActivationEvent, in model: WorkspaceModel) -> UUID? {
        func claims(_ ws: Workspace) -> Bool {
            if let id = event.windowID, ws.windows.contains(where: { $0.windowID == id }) { return true }
            if let bundle = event.bundleID, ws.apps.contains(bundle) { return true }
            return false
        }
        if let active = model.activeWorkspace, claims(active) { return active.id }
        // A specific window assignment beats a whole-app assignment in another workspace.
        if let id = event.windowID,
           let ws = model.workspaces.first(where: { $0.windows.contains { $0.windowID == id } }) { return ws.id }
        return model.workspaces.first(where: claims)?.id
    }
}

/// "Switch to workspace N / next / previous". Workspaces are ordered as in the model.
public enum WorkspaceSwitchCommand: Equatable, Sendable {
    /// One-based index, as typed on the keyboard (1 = first workspace).
    case index(Int)
    case next
    case previous

    /// The target id, or nil when there are no workspaces or the index is out of range.
    /// next/previous wrap around; with no active workspace next is the first and previous the last.
    public func target(in model: WorkspaceModel) -> UUID? {
        let all = model.workspaces
        guard !all.isEmpty else { return nil }
        switch self {
        case .index(let n):
            return (1...all.count).contains(n) ? all[n - 1].id : nil
        case .next, .previous:
            guard let current = model.activeWorkspaceID, let i = all.firstIndex(where: { $0.id == current }) else {
                return self == .next ? all.first?.id : all.last?.id
            }
            let step = self == .next ? 1 : all.count - 1
            return all[(i + step) % all.count].id
        }
    }
}
