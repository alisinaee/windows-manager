import Foundation
import CoreGraphics

// The virtual-workspace model (phase P5.1): named workspaces, which windows belong to each,
// which one is active, and a record of every window currently hidden or parked with its original
// frame, so a crash or a lock can never strand a window off screen. Pure data, no system calls.

/// A window that belongs to a workspace.
public struct WorkspaceWindowRef: Codable, Hashable, Sendable {
    public var windowID: UInt32
    public var pid: Int32
    public var bundleID: String?
    public var title: String?

    public init(windowID: UInt32, pid: Int32, bundleID: String? = nil, title: String? = nil) {
        self.windowID = windowID
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
    }
}

public struct Workspace: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Apps (bundle ids) assigned to the workspace as a whole.
    public var apps: [String]
    /// Individual windows assigned to the workspace.
    public var windows: [WorkspaceWindowRef]

    public init(id: UUID = UUID(), name: String, apps: [String] = [], windows: [WorkspaceWindowRef] = []) {
        self.id = id
        self.name = name
        self.apps = apps
        self.windows = windows
    }
}

/// How a window was taken off screen.
public enum HideMethod: String, Codable, Hashable, Sendable {
    /// The whole app was hidden.
    case appHidden
    /// The window was moved to a screen corner.
    case parked
}

/// A window that is currently hidden or parked, with where it has to go back to.
public struct HiddenWindowRecord: Codable, Hashable, Sendable {
    public var windowID: UInt32
    public var pid: Int32
    public var bundleID: String?
    public var method: HideMethod
    public var originalFrame: CGRect
    /// The workspace the window belongs to, when known.
    public var workspaceID: UUID?

    public init(windowID: UInt32, pid: Int32, bundleID: String? = nil, method: HideMethod,
                originalFrame: CGRect, workspaceID: UUID? = nil) {
        self.windowID = windowID
        self.pid = pid
        self.bundleID = bundleID
        self.method = method
        self.originalFrame = originalFrame
        self.workspaceID = workspaceID
    }
}

public struct WorkspaceModel: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var workspaces: [Workspace]
    public var activeWorkspaceID: UUID?
    public var hiddenRecords: [HiddenWindowRecord]

    public init(schemaVersion: Int = WorkspaceModel.currentSchemaVersion, workspaces: [Workspace] = [],
                activeWorkspaceID: UUID? = nil, hiddenRecords: [HiddenWindowRecord] = []) {
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
        self.hiddenRecords = hiddenRecords
    }

    public var activeWorkspace: Workspace? {
        guard let id = activeWorkspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    public func workspace(_ id: UUID) -> Workspace? { workspaces.first { $0.id == id } }

    /// Adds or replaces the record for a window (one record per window id).
    public mutating func recordHidden(_ record: HiddenWindowRecord) {
        hiddenRecords.removeAll { $0.windowID == record.windowID }
        hiddenRecords.append(record)
    }

    /// Removes the record once the window is back.
    public mutating func clearHidden(windowID: UInt32) {
        hiddenRecords.removeAll { $0.windowID == windowID }
    }
}
