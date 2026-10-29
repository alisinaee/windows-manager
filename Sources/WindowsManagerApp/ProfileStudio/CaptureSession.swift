import AppKit
import WMCore

/// Runs one workspace scan with our own windows out of the way. Stage Manager reacts to the front app: a scan taken
/// while the Studio (or the menu bar popup) is in front would see our app take the front and the stage would move.
@MainActor
enum CaptureSession {
    /// How long Stage Manager gets to settle after our windows are hidden, before the scan starts.
    static let settleDelay: Duration = .milliseconds(700)

    /// Hides our visible windows, waits for the stage to settle, runs `scan` off the main thread, then shows the
    /// windows again. Only the window that had keyboard focus is made key again, so a user who was elsewhere keeps focus.
    static func run<T>(_ scan: @escaping () -> T) async -> T {
        let (hidden, keyBefore) = hideOwnWindows()
        try? await Task.sleep(for: settleDelay)
        let result = await Task.detached(priority: .userInitiated) { scan() }.value
        restore(hidden, keyBefore: keyBefore)
        DebugLog.log("capture", "hid \(hidden.count) own windows, settled 700ms")
        if DebugLog.isEnabled, let workspace = result as? WorkspaceScan {
            for line in WindowDump.lines(for: workspace) { DebugLog.log("capture-window", line) }
        }
        return result
    }

    /// Like `run`, but gives up after `limit` (default 15 s): the windows are shown again and nil is returned, so a hung
    /// scan ends with an error instead of a Studio that never comes back (P6.132). A late scan result is dropped.
    static func runTimed(limit: Duration = CaptureTimeout.defaultLimit, _ scan: @escaping @Sendable () -> WorkspaceScan) async -> WorkspaceScan? {
        let (hidden, keyBefore) = hideOwnWindows()
        try? await Task.sleep(for: settleDelay)
        let result = await CaptureTimeout.race(limit: limit) {
            await Task.detached(priority: .userInitiated) { scan() }.value
        }
        restore(hidden, keyBefore: keyBefore)
        if result == nil { DebugLog.log("capture", "scan timed out after \(limit); windows shown again") }
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

    // MARK: Hiding and showing

    /// Orders out our visible windows. Returns them with the window that had keyboard focus (nil when it was not ours).
    private static func hideOwnWindows() -> ([NSWindow], NSWindow?) {
        let windows = NSApp.windows.filter { window in
            window.isVisible && !window.className.contains("MenuBarExtra")
        }
        let keyBefore = NSApp.keyWindow.flatMap { key in windows.contains { $0 === key } ? key : nil }
        for window in windows { window.orderOut(nil) }
        return (windows, keyBefore)
    }

    /// Shows the hidden windows again without activating the app. Only the window that had focus is made key.
    private static func restore(_ windows: [NSWindow], keyBefore: NSWindow?) {
        for window in windows { window.orderFront(nil) }
        keyBefore?.makeKeyAndOrderFront(nil)
    }
}
