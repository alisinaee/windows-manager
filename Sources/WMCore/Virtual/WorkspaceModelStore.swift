import Foundation
import CoreGraphics

// Saves the workspace model to disk and decides what to repair after a crash or a lock (phase P5.1).
// File: <folder>/workspaces.json, written to a temp file and swapped in, like ProfileStore.
// Default folder: ~/Library/Application Support/WindowsManager/Virtual/.

/// A window that exists right now, as far as recovery needs to know.
public struct VirtualLiveWindow: Hashable, Sendable {
    public var windowID: UInt32
    public var pid: Int32
    public var frame: CGRect
    public var isOnScreen: Bool

    public init(windowID: UInt32, pid: Int32, frame: CGRect, isOnScreen: Bool = true) {
        self.windowID = windowID
        self.pid = pid
        self.frame = frame
        self.isOnScreen = isOnScreen
    }
}

/// One step the caller should carry out through AppHider / CornerParker.
public enum VirtualAction: Hashable, Sendable {
    /// Unhide the whole app.
    case unhideApp(pid: Int32)
    /// Move a parked window back to its frame.
    case restoreFrame(windowID: UInt32, pid: Int32, frame: CGRect)
    /// Hide or park a window that belongs to an inactive workspace.
    case hideWindow(windowID: UInt32, pid: Int32)
}

public struct RecoveryPlan: Equatable, Sendable {
    public var actions: [VirtualAction]
    /// Records dropped because their window is gone.
    public var droppedRecords: [HiddenWindowRecord]
    /// The model to save after the actions ran: stale records and dead window refs removed, and records
    /// that the actions restore cleared.
    public var model: WorkspaceModel
}

public enum WorkspaceModelStoreError: Error, LocalizedError, Equatable {
    case corrupt(String)
    case newerSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let reason): return "The workspace file is damaged: \(reason)"
        case .newerSchema(let v): return "The workspace file uses a newer format (version \(v))."
        }
    }
}

public final class WorkspaceModelStore: @unchecked Sendable {
    public static var defaultFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("WindowsManager", isDirectory: true)
            .appendingPathComponent("Virtual", isDirectory: true)
    }

    public let folder: URL
    public var fileURL: URL { folder.appendingPathComponent("workspaces.json", isDirectory: false) }

    private let fileManager: FileManager
    private let lock = NSLock()

    public init(folder: URL? = nil, fileManager: FileManager = .default) {
        self.folder = folder ?? Self.defaultFolder
        self.fileManager = fileManager
    }

    // MARK: Disk

    public func save(_ model: WorkspaceModel) throws {
        lock.lock(); defer { lock.unlock() }
        var model = model
        model.schemaVersion = WorkspaceModel.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(model)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".workspaces.json.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    /// The saved model, or nil when nothing was saved yet. Throws when the file is damaged or newer.
    public func load() throws -> WorkspaceModel? {
        lock.lock(); defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let model: WorkspaceModel
        do {
            model = try JSONDecoder().decode(WorkspaceModel.self, from: data)
        } catch {
            throw WorkspaceModelStoreError.corrupt(error.localizedDescription)
        }
        if model.schemaVersion > WorkspaceModel.currentSchemaVersion {
            throw WorkspaceModelStoreError.newerSchema(model.schemaVersion)
        }
        return model
    }

    /// Deletes the saved file (no error when there is none).
    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) }
    }

    // MARK: Crash recovery

    /// What to do at launch with a model saved by an earlier run: bring back every window that was left
    /// hidden or parked, and forget records and window refs for windows that no longer exist.
    public static func recover(_ model: WorkspaceModel, live: [VirtualLiveWindow], tolerance: CGFloat = 2) -> RecoveryPlan {
        let liveByID: [UInt32: VirtualLiveWindow] = Dictionary(live.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        var actions: [VirtualAction] = []
        var dropped: [HiddenWindowRecord] = []
        var unhidden = Set<Int32>()

        for record in model.hiddenRecords {
            guard let window = liveByID[record.windowID] else { dropped.append(record); continue }
            switch record.method {
            case .appHidden:
                if unhidden.insert(window.pid).inserted { actions.append(.unhideApp(pid: window.pid)) }
            case .parked:
                if !frame(window.frame, near: record.originalFrame, tolerance: tolerance) {
                    actions.append(.restoreFrame(windowID: record.windowID, pid: window.pid, frame: record.originalFrame))
                }
            }
        }

        var cleaned = model
        cleaned.hiddenRecords = []
        for index in cleaned.workspaces.indices {
            cleaned.workspaces[index].windows.removeAll { liveByID[$0.windowID] == nil }
        }
        return RecoveryPlan(actions: actions, droppedRecords: dropped, model: cleaned)
    }

    // MARK: Lock / unlock / sleep recovery

    /// Re-asserts the active workspace: windows of the active workspace that are hidden or parked come
    /// back, and live windows of other workspaces that are showing get hidden again. Windows that belong
    /// to no workspace are left alone. Does nothing without an active workspace.
    public static func reassertActive(_ model: WorkspaceModel, live: [VirtualLiveWindow], tolerance: CGFloat = 2) -> [VirtualAction] {
        guard let active = model.activeWorkspace else { return [] }
        let activeIDs = Set(active.windows.map(\.windowID))
        let records: [UInt32: HiddenWindowRecord] = Dictionary(model.hiddenRecords.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        var actions: [VirtualAction] = []
        var unhidden = Set<Int32>()

        for window in live where activeIDs.contains(window.windowID) {
            if let record = records[window.windowID], record.method == .parked {
                if !frame(window.frame, near: record.originalFrame, tolerance: tolerance) {
                    actions.append(.restoreFrame(windowID: window.windowID, pid: window.pid, frame: record.originalFrame))
                }
            } else if !window.isOnScreen, records[window.windowID]?.method == .appHidden || records[window.windowID] == nil {
                if unhidden.insert(window.pid).inserted { actions.append(.unhideApp(pid: window.pid)) }
            }
        }

        let otherIDs = Set(model.workspaces.filter { $0.id != active.id }.flatMap(\.windows).map(\.windowID))
            .subtracting(activeIDs)
        for window in live where otherIDs.contains(window.windowID) && window.isOnScreen && records[window.windowID] == nil {
            actions.append(.hideWindow(windowID: window.windowID, pid: window.pid))
        }
        return actions
    }

    private static func frame(_ a: CGRect, near b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
