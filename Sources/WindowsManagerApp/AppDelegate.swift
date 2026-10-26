import AppKit
import OSLog
import WMCore

/// Facts about the running bundle. Falls back to the packaged values when the binary runs outside
/// the .app (for example from `swift run`), so logging and the single-instance guard still work.
enum AppInfo {
    static let fallbackBundleID = "dev.windowsmanager.WindowsManager"

    static var bundleID: String { Bundle.main.bundleIdentifier ?? fallbackBundleID }
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// One logger for the whole app: subsystem = bundle id, so `log stream --predicate 'subsystem == "..."'` works.
    static let logger = Logger(subsystem: bundleID, category: "app")
}

/// `WindowsManagerApp --self-check`: prints version, bundle id, Accessibility trust and the SkyLight
/// load state to stdout, then exits 0. It never creates a window or a menu bar item.
enum SelfCheck {
    static func runAndExit() -> Never {
        print("Windows Manager \(AppInfo.version) (\(AppInfo.build))")
        print("bundle id: \(AppInfo.bundleID)")
        print("accessibility trusted: \(AXPermission.isTrusted())")
        if PrivateSymbols.isLoaded {
            print("skylight: loaded (\(PrivateSymbols.skyLightPath))")
        } else {
            print("skylight: NOT loaded (\(PrivateSymbols.loadError ?? "unknown error"))")
        }
        fflush(stdout)
        exit(0)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isDuplicate = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon and no app menu. Info.plist sets LSUIElement too; this covers unbundled runs.
        NSApp.setActivationPolicy(.accessory)

        // Single instance: if a copy with our bundle id already runs, bring it forward and quit this one.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleID)
            .filter { $0.processIdentifier != myPID }
        if let existing = others.first {
            AppInfo.logger.notice("Another instance runs (pid \(existing.processIdentifier)); activating it and quitting")
            isDuplicate = true
            existing.activate()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isDuplicate else { return }
        AppInfo.logger.notice("Windows Manager \(AppInfo.version) (\(AppInfo.build)) started, pid \(ProcessInfo.processInfo.processIdentifier)")
        AppInfo.logger.notice("SkyLight loaded: \(PrivateSymbols.isLoaded), Accessibility trusted: \(AXPermission.isTrusted())")

        // First run, or Accessibility is missing (for example after a rebuild changed the signature): show setup.
        // --self-check exits before any UI exists; the guard keeps that true if the order of startup ever changes.
        if !CommandLine.arguments.contains("--self-check"),
           !OnboardingWindowController.isCompleted || !AXPermission.isTrusted() {
            OnboardingWindowController.shared.show()
        }

        // Snap overlay (Option-drag): starts only when Accessibility is trusted and a layout exists.
        if !CommandLine.arguments.contains("--self-check") {
            SnapMonitor.shared.startIfPossible()
            NotificationCenter.default.addObserver(forName: .layoutsDidChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SnapMonitor.shared.startIfPossible() }
            }
            // Virtual workspaces: crash recovery now, switching pieces only when the opt-in switch is on.
            WorkspaceController.shared.startIfPossible()
            HotkeyController.shared.start()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isDuplicate else { return }
        for url in urls {
            do {
                let command = try ControlCommand.parse(url: url)
                Task { @MainActor in
                    guard let state = AppState.current else {
                        AppInfo.logger.error("URL ignored, app state not ready: \(url.absoluteString, privacy: .public)")
                        return
                    }
                    state.reloadProfiles()
                    state.handle(command)
                }
            } catch {
                AppInfo.logger.error("Bad control URL \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !isDuplicate { AppInfo.logger.notice("Windows Manager quitting") }
    }
}
