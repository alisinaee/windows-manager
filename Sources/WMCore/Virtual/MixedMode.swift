import Foundation
import CoreGraphics

// Mixed mode (phase P5.5): native full-screen apps together with virtual workspaces.
// A full-screen window lives on its own native Space. Hiding or parking it breaks it, and its frame is
// meaningless to record. So the switcher must never see such windows (nor windows on Spaces the user is not
// looking at, which cannot be moved reliably). While the active native Space is a full-screen Space, a
// workspace switch is deferred until the user is back on a normal desktop.
// Everything here is pure logic over a snapshot; the system reader at the bottom fills the snapshot.

// MARK: - Snapshot

/// What the window server says about Spaces right now.
public struct MixedModeSnapshot: Equatable, Sendable {
    /// Spaces that are visible now (one per display).
    public var visibleSpaceIDs: Set<UInt64>
    /// Every full-screen (or Split View) Space.
    public var fullScreenSpaceIDs: Set<UInt64>
    /// Window id to the Space ids it is on. A missing window is treated as unknown (kept).
    public var windowSpaceIDs: [UInt32: [UInt64]]
    /// Window ids that are full-screen windows (listed by their full-screen Space).
    public var fullScreenWindowIDs: Set<UInt32>
    /// The Space with keyboard focus; nil when unknown.
    public var activeSpaceID: UInt64?

    public init(visibleSpaceIDs: Set<UInt64> = [], fullScreenSpaceIDs: Set<UInt64> = [],
                windowSpaceIDs: [UInt32: [UInt64]] = [:], fullScreenWindowIDs: Set<UInt32> = [],
                activeSpaceID: UInt64? = nil) {
        self.visibleSpaceIDs = visibleSpaceIDs
        self.fullScreenSpaceIDs = fullScreenSpaceIDs
        self.windowSpaceIDs = windowSpaceIDs
        self.fullScreenWindowIDs = fullScreenWindowIDs
        self.activeSpaceID = activeSpaceID
    }

    /// The user is looking at a full-screen app's Space.
    public var activeSpaceIsFullScreen: Bool {
        guard let activeSpaceID else { return false }
        return fullScreenSpaceIDs.contains(activeSpaceID)
    }

    public func isFullScreen(windowID: UInt32) -> Bool {
        if fullScreenWindowIDs.contains(windowID) { return true }
        guard let spaces = windowSpaceIDs[windowID], !spaces.isEmpty else { return false }
        return spaces.contains { fullScreenSpaceIDs.contains($0) }
    }

    /// True when the window is on a visible Space, or when nothing is known about it (never drop on a guess).
    public func isOnCurrentSpace(windowID: UInt32) -> Bool {
        guard !visibleSpaceIDs.isEmpty, let spaces = windowSpaceIDs[windowID], !spaces.isEmpty else { return true }
        return spaces.contains { visibleSpaceIDs.contains($0) }
    }
}

public protocol MixedModeSpaceInfo {
    func snapshot(forWindows windowIDs: [UInt32]) -> MixedModeSnapshot
}

// MARK: - Filter

public enum MixedModeFilter {
    /// Removes full-screen windows and windows that are not on a visible Space.
    public static func filter(_ windows: [VirtualLiveWindow], snapshot: MixedModeSnapshot) -> [VirtualLiveWindow] {
        windows.filter { !snapshot.isFullScreen(windowID: $0.windowID) && snapshot.isOnCurrentSpace(windowID: $0.windowID) }
    }
}

/// Decorator for the switcher's window source: the switcher never learns that full-screen windows or
/// windows of other Spaces exist, so it can neither hide, park, record nor restore them.
public struct FullScreenAwareWindowSource: WorkspaceWindowSource {
    private let base: WorkspaceWindowSource
    private let info: MixedModeSpaceInfo

    public init(base: WorkspaceWindowSource, info: MixedModeSpaceInfo) {
        self.base = base
        self.info = info
    }

    public func liveWindows() -> [VirtualLiveWindow] {
        let all = base.liveWindows()
        return MixedModeFilter.filter(all, snapshot: info.snapshot(forWindows: all.map(\.windowID)))
    }

    public func bundleID(ofPID pid: Int32) -> String? { base.bundleID(ofPID: pid) }

    /// Unfiltered: windows on other Spaces still exist, they are only not visible to the switcher.
    public func allWindows() -> [VirtualLiveWindow] { base.allWindows() }
}

/// A whole `WorkspaceSystem` whose window source is wrapped by `FullScreenAwareWindowSource`;
/// hiding and frame calls go straight to the base system.
public struct FullScreenAwareSystem: WorkspaceSystem {
    private let base: WorkspaceSystem
    private let source: FullScreenAwareWindowSource

    public init(base: WorkspaceSystem, info: MixedModeSpaceInfo) {
        self.base = base
        self.source = FullScreenAwareWindowSource(base: base, info: info)
    }

    public func liveWindows() -> [VirtualLiveWindow] { source.liveWindows() }
    public func bundleID(ofPID pid: Int32) -> String? { source.bundleID(ofPID: pid) }
    public func allWindows() -> [VirtualLiveWindow] { source.allWindows() }
    public func hideApp(pid: Int32) -> Bool { base.hideApp(pid: pid) }
    public func unhideApp(pid: Int32) -> Bool { base.unhideApp(pid: pid) }
    public func frame(ofWindow windowID: UInt32, pid: Int32) -> CGRect? { base.frame(ofWindow: windowID, pid: pid) }
    public func setPosition(_ origin: CGPoint, ofWindow windowID: UInt32, pid: Int32) -> Bool {
        base.setPosition(origin, ofWindow: windowID, pid: pid)
    }
    public func setFrame(_ frame: CGRect, ofWindow windowID: UInt32, pid: Int32) -> Bool {
        base.setFrame(frame, ofWindow: windowID, pid: pid)
    }
    public func screenFrames() -> [CGRect] { base.screenFrames() }
}

// MARK: - Deferred switch

/// Holds the latest workspace switch asked for while a full-screen Space is active.
public struct DeferredSwitch: Equatable, Sendable {
    public private(set) var pending: UUID?

    public init(pending: UUID? = nil) { self.pending = pending }

    public var hasPending: Bool { pending != nil }

    /// A switch was asked for. Returns the target when it should be applied now, nil when it was deferred.
    /// The latest request wins; a request now applied clears an older pending one.
    public mutating func request(_ target: UUID, activeSpaceIsFullScreen: Bool) -> UUID? {
        if activeSpaceIsFullScreen {
            pending = target
            return nil
        }
        pending = nil
        return target
    }

    /// The active native Space changed. Returns the pending target to apply now (and clears it), or nil
    /// when nothing is pending, the user is still on a full-screen Space, or the target is already applied.
    public mutating func activeSpaceChanged(activeSpaceIsFullScreen: Bool, appliedWorkspace: UUID?) -> UUID? {
        guard let target = pending, !activeSpaceIsFullScreen else { return nil }
        pending = nil
        return target == appliedWorkspace ? nil : target
    }

    /// The pending switch is no longer wanted (feature off, workspace deleted).
    public mutating func cancel() { pending = nil }
}

// MARK: - Real implementation

/// Reads Spaces through SkyLight (SpaceReader).
public struct SystemMixedModeSpaceInfo: MixedModeSpaceInfo {
    public init() {}

    public func snapshot(forWindows windowIDs: [UInt32]) -> MixedModeSnapshot {
        let displays = (try? SpaceReader.displays()) ?? []
        var visible = Set<UInt64>(), full = Set<UInt64>(), fullWindows = Set<UInt32>()
        for d in displays {
            visible.insert(d.currentSpaceID)
            for s in d.spaces where s.kind == .fullscreen {
                full.insert(s.id)
                fullWindows.formUnion(s.fullScreenWindowIDs)
            }
        }
        let active = SpaceReader.activeSpaceID()
        return MixedModeSnapshot(visibleSpaceIDs: visible, fullScreenSpaceIDs: full,
                                 windowSpaceIDs: SpaceReader.spaces(forWindows: windowIDs),
                                 fullScreenWindowIDs: fullWindows, activeSpaceID: active == 0 ? nil : active)
    }

    /// Cheap check for "is the user on a full-screen Space now" (no per-window lookups).
    public static func activeSpaceIsFullScreen() -> Bool {
        MixedModeSpaceInfoProbe.activeIsFullScreen()
    }
}

enum MixedModeSpaceInfoProbe {
    static func activeIsFullScreen() -> Bool {
        let active = SpaceReader.activeSpaceID()
        guard active != 0, let displays = try? SpaceReader.displays() else { return false }
        return displays.flatMap(\.spaces).contains { $0.id == active && $0.kind == .fullscreen }
    }
}
