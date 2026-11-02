import AppKit
import WMCore

/// Runs one workspace scan. Our own windows are never hidden or closed (P9.15): `scanWorkspace` leaves them out.
@MainActor
enum CaptureSession {
    /// Runs `scan` off the main thread; nothing is hidden.
    static func run<T>(_ scan: @escaping () -> T) async -> T {
        let result = await Task.detached(priority: .userInitiated) { scan() }.value
        if DebugLog.isEnabled, let workspace = result as? WorkspaceScan {
            for line in WindowDump.lines(for: workspace) { DebugLog.log("capture-window", line) }
        }
        return result
    }

    /// Like `run`, but gives up after `limit` (default 15 s): nil is returned, so a hung
    /// scan ends with an error (P6.132). A late scan result is dropped.
    static func runTimed(limit: Duration = CaptureTimeout.defaultLimit, _ scan: @escaping @Sendable () -> WorkspaceScan) async -> WorkspaceScan? {
        let result = await CaptureTimeout.race(limit: limit) {
            await Task.detached(priority: .userInitiated) { scan() }.value
        }
        if result == nil { DebugLog.log("capture", "scan timed out after \(limit)") }
        return result
    }

    /// The workspace as WMCore scans it, minus our own app's windows (matched by bundle id or owner name), so a
    /// captured profile never contains Windows Manager itself.
    nonisolated static func scanWorkspace() -> WorkspaceScan {
        var scan = WorkspaceScanner.scan()
        let ownID = Bundle.main.bundleIdentifier?.lowercased()
        scan.windows.removeAll { window in
            (ownID != nil && window.app.bundleID?.lowercased() == ownID) || window.app.name == "Windows Manager"
        }
        return scan
    }

    /// One scan for Live sync (P6.67), off the main thread and without hiding anything: the Studio stays where it is and
    /// `scanWorkspace` leaves our own windows out. Only the first capture hides the windows (`run`).
    static func scanNow() async -> WorkspaceScan {
        await Task.detached(priority: .utility) { scanWorkspace() }.value
    }
}
