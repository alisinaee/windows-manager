import AppKit
import SwiftUI
import WMCore

/// `windowsmanager://open?...` for UX capture. Active only with env WM_UX_TEST=1 (otherwise ignored).
/// When a route is fully applied it writes `/tmp/wm-ux-ready.json` (`{"window": <CGWindowID>, "title": ...}`) so
/// `scripts/ux-capture.sh` waits for it and captures exactly that window instead of guessing the largest one.
@MainActor
enum UXTestRoute {
    static let readyPath = "/tmp/wm-ux-ready.json"

    /// True when the URL was an open route (handled or refused), so the caller skips `ControlCommand`.
    static func handleIfOpenRoute(_ url: URL) -> Bool {
        guard UXOpenRoute.matches(url) else { return false }
        guard UXOpenRoute.isEnabled() else {
            AppInfo.logger.notice("UX open route ignored: WM_UX_TEST is not 1")
            return true
        }
        do {
            let route = try UXOpenRoute.parse(url: url)
            Task { @MainActor in await run(route) }
        } catch {
            AppInfo.logger.error("Bad UX route \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return true
    }

    /// Windows kept alive by the route itself (popover, fallback settings).
    private static var standalone: NSWindow?

    static func run(_ route: UXOpenRoute) async {
        try? FileManager.default.removeItem(atPath: readyPath)
        if let a = route.appearance { NSApp.appearance = NSAppearance(named: a == .dark ? .darkAqua : .aqua) }
        // The onboarding view reads the override when its window is created, so start it fresh.
        OnboardingModel.uxAccessibilityOverride = route.permission.map { $0 == .after }
        if route.section == .onboarding { closeWindows { $0.title == "Set up Windows Manager" } }
        standalone?.close(); standalone = nil
        AppState.current?.reloadProfiles()

        var target: NSWindow?
        switch route.section {
        case .studio:
            ProfileStudioModel.uxInspectorTab = route.inspectorTab.map {
                switch $0 { case .inspector: return .inspector; case .options: return .options; case .launch: return .launchOrder }
            }
            ProfileStudioWindowController.shared.show()
            target = await waitForWindow { ProfileStudioModel.isStudioWindow($0) }
            // Size first so the layout the sheet or tile selection sees is the final one.
            if let size = route.size, let target { await applySize(size, to: target) }
            if let model = ProfileStudioModel.uxCurrent() {
                await model.uxApply(profile: route.profile, mode: route.mode, sheet: route.sheet,
                                    selectTile: route.selectTile, saveName: route.saveName)
            }
        case .settings:
            target = await openSettings()
        case .onboarding:
            OnboardingWindowController.shared.show()
            target = await waitForWindow { $0.title == "Set up Windows Manager" }
        case .debug:
            if let state = AppState.current {
                DebugWindowController.shared.show(store: state.store) { [weak state] in state?.reloadProfiles() }
            }
            target = await waitForWindow { $0.title == "Debug Tests" }
        case .popover:
            target = showPopover()
        }
        if route.section != .studio, let size = route.size, let target { await applySize(size, to: target) }
        // Let SwiftUI lay out the sheet or popover before the caller captures.
        try? await Task.sleep(for: .milliseconds(500))
        if let target {
            target.orderFrontRegardless()
            writeReady(target)
        }
    }

    private static func writeReady(_ window: NSWindow) {
        let json = "{\"window\": \(window.windowNumber), \"title\": \"\(window.title)\"}"
        try? json.write(toFile: readyPath, atomically: true, encoding: .utf8)
    }

    private static func closeWindows(where match: (NSWindow) -> Bool) {
        for w in NSApp.windows where match(w) { w.close() }
    }

    private static func waitForWindow(_ match: (NSWindow) -> Bool) async -> NSWindow? {
        for _ in 0..<60 {
            if let w = NSApp.windows.first(where: { $0.isVisible && match($0) }) { return w }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Sets the content size, keeping the top-left corner. Re-applies on later runloop turns until it sticks.
    private static func applySize(_ size: CGSize, to window: NSWindow) async {
        for _ in 0..<8 {
            let want = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
            if abs(window.frame.width - want.width) < 1, abs(window.frame.height - want.height) < 1 { break }
            var frame = window.frame
            frame.origin.y += frame.height - want.height
            frame.size = want
            window.setFrame(frame, display: true)
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Settings

    private static func openSettings() async -> NSWindow? {
        let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            if let w = NSApp.windows.first(where: { $0.isVisible && !before.contains(ObjectIdentifier($0)) && $0.styleMask.contains(.titled) }) { return w }
        }
        // The Settings scene did not open from an accessory app: host the same view in a plain window.
        guard let state = AppState.current else { return nil }
        let host = NSHostingController(rootView: SettingsView().environmentObject(state))
        let window = NSWindow(contentViewController: host)
        window.title = "Settings (UX)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        standalone = window
        return window
    }

    // MARK: Popover

    /// The menu bar popover cannot be opened from outside, so the same content is hosted in a regular window.
    private static func showPopover() -> NSWindow? {
        guard let state = AppState.current else { return nil }
        let view = MenuBarContent()
            .environmentObject(state)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Menu bar popover (UX)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(host.view.fittingSize)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        standalone = window
        return window
    }
}
