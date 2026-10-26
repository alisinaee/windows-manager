import AppKit
import ApplicationServices
import Foundation
import CoreGraphics

// The production hide/show engine for virtual workspaces (phase P5.2).
// A switch hides what belongs to the old workspace (the whole app when all of its windows are in the old
// workspace, otherwise each window is parked in a screen corner), then brings back the target workspace.
// Every hidden window is written to the model (HiddenWindowRecord, with its original frame) and the model
// is saved BEFORE the window is touched, so a crash can never strand a window: P5.1 recovery brings it back.
// All system calls go through the protocols below, so the engine is unit-testable with fakes.

// MARK: - OS side effects

/// Lists live windows and tells which app a process is.
public protocol WorkspaceWindowSource {
    /// Every normal window the window server lists, including hidden and parked ones.
    func liveWindows() -> [VirtualLiveWindow]
    func bundleID(ofPID pid: Int32) -> String?
    /// Every window that exists, even ones a filter hides from `liveWindows()` (other native Spaces).
    /// Used to tell "not visible to the filter" from "closed". Defaults to `liveWindows()`.
    func allWindows() -> [VirtualLiveWindow]
}

public extension WorkspaceWindowSource {
    func allWindows() -> [VirtualLiveWindow] { liveWindows() }
}

/// Hides and unhides a whole app.
public protocol AppVisibilityControlling {
    /// True when the app is hidden afterwards.
    func hideApp(pid: Int32) -> Bool
    /// True when the app is no longer hidden afterwards.
    func unhideApp(pid: Int32) -> Bool
}

/// Reads and sets window frames (Accessibility coordinates: origin top-left, y down).
public protocol WindowFrameControlling {
    func frame(ofWindow windowID: UInt32, pid: Int32) -> CGRect?
    @discardableResult func setPosition(_ origin: CGPoint, ofWindow windowID: UInt32, pid: Int32) -> Bool
    /// Size, position, size: the strong restore.
    @discardableResult func setFrame(_ frame: CGRect, ofWindow windowID: UInt32, pid: Int32) -> Bool
    /// Frames of all screens in the same coordinate space, main screen first.
    func screenFrames() -> [CGRect]
}

public typealias WorkspaceSystem = WorkspaceWindowSource & AppVisibilityControlling & WindowFrameControlling

public protocol WorkspaceModelSaving {
    func save(_ model: WorkspaceModel) throws
}

extension WorkspaceModelStore: WorkspaceModelSaving {}

// MARK: - Result

public struct WorkspaceSwitchResult: Equatable, Sendable {
    public var fromWorkspaceID: UUID?
    public var toWorkspaceID: UUID
    /// Nothing had to change (the target was already active and nothing was hidden).
    public var wasNoOp = false
    public var hiddenApps: [Int32] = []
    public var parkedWindows: [UInt32] = []
    public var unhiddenApps: [Int32] = []
    public var restoredWindows: [UInt32] = []
    /// Windows of the target workspace that no longer exist.
    public var missingWindows: [UInt32] = []
    public var saveCount = 0
    public var hideSeconds: TimeInterval = 0
    public var showSeconds: TimeInterval = 0
    public var totalSeconds: TimeInterval = 0
    public var warnings: [String] = []

    public var hasWarnings: Bool { !warnings.isEmpty }
}

public enum WorkspaceSwitchError: Error, LocalizedError, Equatable {
    case unknownWorkspace(UUID)
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownWorkspace(let id): return "There is no workspace with id \(id.uuidString)."
        case .saveFailed(let why): return "The workspace file could not be saved, so nothing was moved: \(why)"
        }
    }
}

// MARK: - Engine

public final class WorkspaceSwitcher {
    public private(set) var model: WorkspaceModel
    private let system: WorkspaceSystem
    private let saver: WorkspaceModelSaving
    private let clock: () -> TimeInterval
    private let tolerance: CGFloat
    private var saveCount = 0

    public init(model: WorkspaceModel, system: WorkspaceSystem, saver: WorkspaceModelSaving,
                tolerance: CGFloat = 2,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.model = model
        self.system = system
        self.saver = saver
        self.tolerance = tolerance
        self.clock = clock
    }

    /// Switches from the active workspace (if any) to `targetID`.
    /// Throws only before anything was moved (unknown id, or the model cannot be saved). Problems after
    /// that become warnings in the result.
    @discardableResult
    public func switchTo(_ targetID: UUID) throws -> WorkspaceSwitchResult {
        guard let target = model.workspace(targetID) else { throw WorkspaceSwitchError.unknownWorkspace(targetID) }
        let started = clock()
        saveCount = 0
        var result = WorkspaceSwitchResult(fromWorkspaceID: model.activeWorkspaceID, toWorkspaceID: targetID)

        let old = model.activeWorkspace.flatMap { $0.id == targetID ? nil : $0 }
        let hasTargetRecords = model.hiddenRecords.contains { belongs(record: $0, to: target) }
        if model.activeWorkspaceID == targetID && !hasTargetRecords {
            result.wasNoOp = true
            result.totalSeconds = clock() - started
            return result
        }

        // 1. Hide.
        let hideStart = clock()
        if let old { try hide(old: old, keeping: target, into: &result) }
        result.hideSeconds = clock() - hideStart

        // 2. Make the target active (saved: from here on a crash leaves the target active).
        model.activeWorkspaceID = targetID
        try persistBeforeAction()

        // 3. Show.
        let showStart = clock()
        show(target: target, into: &result)
        reassertOthersHidden(into: &result)
        result.showSeconds = clock() - showStart

        result.saveCount = saveCount
        result.totalSeconds = clock() - started
        return result
    }

    // MARK: Hide

    private func hide(old: Workspace, keeping target: Workspace, into result: inout WorkspaceSwitchResult) throws {
        let live = system.liveWindows()
        // Windows on other native Spaces count as "others" too, so use the unfiltered list for that.
        var everything = live
        let liveIDs = Set(live.map(\.windowID))
        everything.append(contentsOf: system.allWindows().filter { !liveIDs.contains($0.windowID) })
        let liveByPID = Dictionary(grouping: everything, by: \.pid)
        let recorded = Set(model.hiddenRecords.map(\.windowID))
        var bundles: [Int32: String?] = [:]
        func bundle(_ pid: Int32) -> String? {
            if let cached = bundles[pid] { return cached }
            let found = system.bundleID(ofPID: pid)
            bundles[pid] = .some(found)
            return found
        }
        func belongs(_ w: VirtualLiveWindow, to ws: Workspace) -> Bool {
            ws.windows.contains { $0.windowID == w.windowID } || (bundle(w.pid).map { ws.apps.contains($0) } ?? false)
        }

        let toHide = live.filter {
            $0.isOnScreen && !recorded.contains($0.windowID) && belongs($0, to: old) && !belongs($0, to: target)
        }
        let hideIDs = Set(toHide.map(\.windowID))
        let parkedIDs = Set(model.hiddenRecords.filter { $0.method == .parked }.map(\.windowID))
        let pids = Array(Set(toHide.map(\.pid))).sorted()

        for pid in pids {
            let mine = toHide.filter { $0.pid == pid }
            // Hiding the whole app also hides windows that are visible now, parked ones and windows of other
            // workspaces (which would be stranded under a hidden app when their workspace is shown).
            let others = (liveByPID[pid] ?? []).filter { w in
                guard !hideIDs.contains(w.windowID) else { return false }
                return w.isOnScreen || parkedIDs.contains(w.windowID)
                    || model.workspaces.contains { $0.id != old.id && belongs(w, to: $0) }
            }
            let wholeApp = others.isEmpty
            var parkList = mine
            if wholeApp {
                if try hideWholeApp(pid: pid, windows: mine, bundleID: bundle(pid), workspace: old.id, into: &result) {
                    parkList = []
                }
            }
            for window in parkList {
                try park(window, bundleID: bundle(window.pid), workspace: old.id, into: &result)
            }
        }
    }

    /// Returns true when the app is hidden. On failure the records are removed again and the caller parks.
    private func hideWholeApp(pid: Int32, windows: [VirtualLiveWindow], bundleID: String?, workspace: UUID,
                              into result: inout WorkspaceSwitchResult) throws -> Bool {
        for w in windows {
            let original = system.frame(ofWindow: w.windowID, pid: pid) ?? w.frame
            model.recordHidden(HiddenWindowRecord(windowID: w.windowID, pid: pid, bundleID: bundleID,
                                                  method: .appHidden, originalFrame: original, workspaceID: workspace))
        }
        try persistBeforeAction()
        if system.hideApp(pid: pid) {
            result.hiddenApps.append(pid)
            return true
        }
        result.warnings.append("App \(bundleID ?? "pid \(pid)") would not hide; its windows are parked instead.")
        for w in windows { model.clearHidden(windowID: w.windowID) }
        persistAfterAction(into: &result)
        return false
    }

    private func park(_ window: VirtualLiveWindow, bundleID: String?, workspace: UUID?, originalOverride: CGRect? = nil,
                      into result: inout WorkspaceSwitchResult) throws {
        let original = originalOverride ?? system.frame(ofWindow: window.windowID, pid: window.pid) ?? window.frame
        let screens = system.screenFrames()
        guard let index = CornerParker.screenIndex(containing: original, screens: screens) else {
            result.warnings.append("Window \(window.windowID) was not parked: no screens were found.")
            return
        }
        let others = screens.enumerated().filter { $0.offset != index }.map(\.element)
        let corner = CornerParker.preferredCorner(windowSize: original.size, screenFrame: screens[index], otherScreens: others)
        let target = CornerParker.parkedOrigin(windowSize: original.size, screenFrame: screens[index], corner: corner)

        model.recordHidden(HiddenWindowRecord(windowID: window.windowID, pid: window.pid, bundleID: bundleID,
                                              method: .parked, originalFrame: original, workspaceID: workspace))
        try persistBeforeAction()
        let accepted = system.setPosition(target, ofWindow: window.windowID, pid: window.pid)
        if !accepted {
            // Nothing moved as far as we know; keep the record anyway if the frame changed.
            if let now = system.frame(ofWindow: window.windowID, pid: window.pid), !near(now.origin, original.origin) {
                result.parkedWindows.append(window.windowID)
                result.warnings.append("Window \(window.windowID) reported a park failure but did move; it is recorded as parked.")
            } else {
                model.clearHidden(windowID: window.windowID)
                persistAfterAction(into: &result)
                result.warnings.append("Window \(window.windowID) could not be parked and stays visible.")
            }
            return
        }
        if let now = system.frame(ofWindow: window.windowID, pid: window.pid), near(now.origin, original.origin) {
            result.warnings.append("Window \(window.windowID) did not move when parked.")
        }
        result.parkedWindows.append(window.windowID)
    }

    // MARK: Show

    private func show(target: Workspace, into result: inout WorkspaceSwitchResult) {
        var live = system.liveWindows()
        let everExisting = Set(system.allWindows().map(\.windowID))
        let records = model.hiddenRecords.filter { belongs(record: $0, to: target) }

        // Whole apps first.
        let appPIDs = Array(Set(records.filter { $0.method == .appHidden }.map(\.pid))).sorted()
        var strangers: [HiddenWindowRecord] = []
        var unhiddenIDs: [UInt32] = []
        for pid in appPIDs {
            if system.unhideApp(pid: pid) {
                result.unhiddenApps.append(pid)
                for r in model.hiddenRecords where r.pid == pid && r.method == .appHidden {
                    if belongs(record: r, to: target) {
                        unhiddenIDs.append(r.windowID)
                        model.clearHidden(windowID: r.windowID)
                    } else {
                        // Another workspace's window: the unhide showed it, so it must go back out of sight.
                        strangers.append(r)
                    }
                }
                persistAfterAction(into: &result)
            } else {
                result.warnings.append("App with pid \(pid) would not unhide; its records are kept for recovery.")
            }
        }

        // The unhide changes what the window server lists: look again.
        live = system.liveWindows()
        let liveIDs = Set(live.map(\.windowID))
        result.restoredWindows.append(contentsOf: unhiddenIDs.filter { liveIDs.contains($0) })
        for r in strangers {
            if let window = live.first(where: { $0.windowID == r.windowID }) {
                do {
                    try park(window, bundleID: r.bundleID, workspace: r.workspaceID, originalOverride: r.originalFrame, into: &result)
                } catch {
                    result.warnings.append("Window \(r.windowID) could not be parked again: \(error.localizedDescription)")
                }
            } else if !everExisting.contains(r.windowID) {
                model.clearHidden(windowID: r.windowID)
                persistAfterAction(into: &result)
            }
        }

        // Then parked windows.
        for record in records where record.method == .parked {
            guard liveIDs.contains(record.windowID) else {
                if everExisting.contains(record.windowID) {
                    // Alive, but on another native Space: keep the record, restore it later.
                    result.warnings.append("Window \(record.windowID) is on another Space; its restore is deferred and its record is kept.")
                    continue
                }
                model.clearHidden(windowID: record.windowID)
                persistAfterAction(into: &result)
                result.missingWindows.append(record.windowID)
                result.warnings.append("Window \(record.windowID) no longer exists; its record was dropped.")
                continue
            }
            if restore(record) {
                model.clearHidden(windowID: record.windowID)
                persistAfterAction(into: &result)
                result.restoredWindows.append(record.windowID)
            } else {
                result.warnings.append("Window \(record.windowID) did not return to its original frame; its record is kept for recovery.")
            }
        }

        // Target windows that are gone and were never hidden.
        for ref in target.windows where !liveIDs.contains(ref.windowID) && !everExisting.contains(ref.windowID)
            && !result.missingWindows.contains(ref.windowID) {
            result.missingWindows.append(ref.windowID)
            result.warnings.append("Window \(ref.windowID) of workspace \"\(target.name)\" no longer exists.")
        }
    }

    private func restore(_ record: HiddenWindowRecord) -> Bool {
        func back() -> Bool {
            guard let f = system.frame(ofWindow: record.windowID, pid: record.pid) else { return false }
            return Self.near(f, record.originalFrame, tolerance: tolerance)
        }
        system.setPosition(record.originalFrame.origin, ofWindow: record.windowID, pid: record.pid)
        if back() { return true }
        system.setFrame(record.originalFrame, ofWindow: record.windowID, pid: record.pid)
        return back()
    }

    /// After an app unhide, windows of other workspaces may be showing again: park them (P5.1 reassertActive).
    private func reassertOthersHidden(into result: inout WorkspaceSwitchResult) {
        let live = system.liveWindows()
        for action in WorkspaceModelStore.reassertActive(model, live: live, tolerance: tolerance) {
            guard case .hideWindow(let windowID, let pid) = action,
                  let window = live.first(where: { $0.windowID == windowID }) else { continue }
            let bundle = system.bundleID(ofPID: pid)
            let owner = model.workspaces.first { ws in ws.windows.contains { $0.windowID == windowID } }
                ?? model.workspaces.first { ws in bundle.map { ws.apps.contains($0) } ?? false && ws.id != model.activeWorkspaceID }
            do {
                try park(window, bundleID: bundle, workspace: owner?.id, into: &result)
            } catch {
                result.warnings.append("Window \(windowID) could not be parked again: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Helpers

    private func belongs(record: HiddenWindowRecord, to ws: Workspace) -> Bool {
        ws.windows.contains { $0.windowID == record.windowID } || (record.bundleID.map { ws.apps.contains($0) } ?? false)
    }

    private func persistBeforeAction() throws {
        do { try saver.save(model); saveCount += 1 } catch { throw WorkspaceSwitchError.saveFailed(error.localizedDescription) }
    }

    private func persistAfterAction(into result: inout WorkspaceSwitchResult) {
        do { try saver.save(model); saveCount += 1 } catch {
            result.warnings.append("The workspace file could not be saved: \(error.localizedDescription)")
        }
    }

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    private static func near(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

// MARK: - Real implementation

/// The real system side: CGWindowList (WindowListReader), NSRunningApplication hide/unhide (as in AppHider),
/// and Accessibility frames (AXWindows, as in CornerParker). Needs Accessibility permission for frames.
public struct SystemWorkspaceBackend: WorkspaceSystem {
    public var hideTimeout: TimeInterval
    public var pollInterval: TimeInterval

    public init(hideTimeout: TimeInterval = 1.5, pollInterval: TimeInterval = 0.02) {
        self.hideTimeout = hideTimeout
        self.pollInterval = pollInterval
    }

    public func liveWindows() -> [VirtualLiveWindow] {
        WindowListReader.windows().map {
            VirtualLiveWindow(windowID: $0.windowID, pid: $0.pid, frame: $0.bounds, isOnScreen: $0.isOnScreen)
        }
    }

    public func bundleID(ofPID pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    public func hideApp(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              AppHider.problem(with: app) == nil, app.hide() else { return false }
        return poll { AppHider.isHidden(pid: pid) }
    }

    public func unhideApp(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), app.unhide() else { return false }
        return poll { !AppHider.isHidden(pid: pid) }
    }

    public func frame(ofWindow windowID: UInt32, pid: Int32) -> CGRect? {
        axWindow(windowID, pid: pid).flatMap { AXWindows.frame(of: $0) }
    }

    public func setPosition(_ origin: CGPoint, ofWindow windowID: UInt32, pid: Int32) -> Bool {
        axWindow(windowID, pid: pid).map { AXWindows.setPosition(origin, of: $0) } ?? false
    }

    public func setFrame(_ frame: CGRect, ofWindow windowID: UInt32, pid: Int32) -> Bool {
        axWindow(windowID, pid: pid).map { AXWindows.setFrame(frame, of: $0) } ?? false
    }

    public func screenFrames() -> [CGRect] { CornerParker.screenFrames() }

    private func axWindow(_ windowID: UInt32, pid: Int32) -> AXUIElement? {
        guard AXPermission.isTrusted(), let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return AXWindows.windows(of: app).first { AXWindows.windowID(of: $0) == windowID }
    }

    private func poll(_ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + hideTimeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return condition()
    }
}
