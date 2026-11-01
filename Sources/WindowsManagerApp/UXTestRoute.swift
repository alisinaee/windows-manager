import AppKit
import SwiftUI
import WMCore

/// `windowsmanager://open?...` for UX capture. Active only with env WM_UX_TEST=1 (otherwise ignored).
/// When a route is fully applied it writes `/tmp/wm-ux-ready.json` (`{"window": <CGWindowID>, "title": ...}`) so
/// `scripts/ux-capture.sh` waits for it and captures exactly that window instead of guessing the largest one.
@MainActor
enum UXTestRoute {
    static let readyPath = "/tmp/wm-ux-ready.json"

    /// True with WM_UX_TEST=1: windows then show without taking the focus (the user keeps working elsewhere).
    static var isBackground: Bool { UXOpenRoute.isEnabled() }

    /// The screen picked by WM_UX_DISPLAY: a 1-based index into `NSScreen.screens`, "secondary" (first screen
    /// without the menu bar), "largest", or a screen name (`localizedName`, case-insensitive, exact or contains).
    /// Nil when unset or unusable, so the caller keeps the default placement.
    static func chosenScreen(environment: [String: String] = ProcessInfo.processInfo.environment) -> NSScreen? {
        guard let value = environment["WM_UX_DISPLAY"], !value.isEmpty else { return nil }
        let screens = NSScreen.screens
        let described = screens.map { UXScreenChoice.Screen(name: $0.localizedName, area: $0.frame.width * $0.frame.height) }
        return UXScreenChoice.pick(value, screens: described).map { screens[$0] }
    }

    /// Never activates the app in test mode (the user keeps working elsewhere). Use instead of `NSApp.activate()`.
    static func activateUnlessBackground() {
        if !isBackground { NSApp.activate() }
    }

    private static var guardObservers: [NSObjectProtocol] = []
    private static var lastGuardRun = Date.distantPast

    /// UX test mode only: keeps every visible window (alerts, panels, onboarding, settings, debug) on the chosen
    /// screen. Moves strays on window / screen / key changes and, throttled, on every app update.
    static func installWindowGuard() {
        guard isBackground, chosenScreen() != nil, guardObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification,
                                          NSWindow.didBecomeMainNotification, NSApplication.didUpdateNotification]
        for name in names {
            guardObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    if name == NSApplication.didUpdateNotification {
                        guard Date().timeIntervalSince(lastGuardRun) > 0.25 else { return }
                        lastGuardRun = Date()
                    }
                    keepOnChosenScreen()
                }
            })
        }
        keepOnChosenScreen()
    }

    /// Moves every visible titled window or panel that is not on the chosen screen into it. Sheets follow their parent.
    static func keepOnChosenScreen() {
        guard isBackground, let target = chosenScreen() else { return }
        for w in NSApp.windows where w.isVisible && w.sheetParent == nil && w.parent == nil
            && (w.styleMask.contains(.titled) || w is NSPanel) && w.screen != target {
            place(w)
        }
    }

    /// Centers the window in the chosen screen's visible frame, clamping its size to it. No-op without WM_UX_DISPLAY.
    static func place(_ window: NSWindow) {
        guard isBackground, let visible = chosenScreen()?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(frame, display: true)
    }

    /// Shows a window the way the route needs it: without focus in test mode.
    private static func present(_ window: NSWindow) {
        if isBackground {
            window.orderFrontRegardless()
        } else {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

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
            if let target { place(target) }
            if let model = ProfileStudioModel.uxCurrent() {
                await model.uxApply(profile: route.profile, mode: route.mode, sheet: route.sheet,
                                    selectTile: route.selectTile, saveName: route.saveName, sidebar: route.sidebar)
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
        if route.section != .studio, let target { place(target) }
        // Let SwiftUI lay out the sheet or popover before the caller captures.
        try? await Task.sleep(for: .milliseconds(500))
        if let target {
            target.orderFrontRegardless()
            await waitForStableFrame(target)
            // WM_UX_KEY=1: make the window key (active-looking controls and selection) without activating the app.
            if ProcessInfo.processInfo.environment["WM_UX_KEY"] == "1" { target.makeKey() }
            writeReady(target)
        }
    }

    /// Waits (up to ~1.5 s) until the frame has not changed for three samples, so the ready file holds the final
    /// rect (late clamping or resizing used to leave the region capture pointing at the wrong place).
    private static func waitForStableFrame(_ window: NSWindow) async {
        var last = window.frame
        var stable = 0
        for _ in 0..<30 where stable < 3 {
            try? await Task.sleep(for: .milliseconds(50))
            stable = window.frame == last ? stable + 1 : 0
            last = window.frame
        }
    }

    private static func writeReady(_ window: NSWindow) {
        // Global top-left coordinates (origin: top-left of the menu bar screen; other displays can be negative).
        // "rect" is the window frame; "region" adds a margin for popovers, clamped to the window's own screen, so
        // `screencapture -R` never needs clamping to 0 (that broke captures on displays left of or above the main one).
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        func topLeft(_ r: NSRect) -> NSRect { NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height) }
        let f = topLeft(window.frame)
        var region = f.insetBy(dx: -40, dy: -40)
        region.size.width += 80   // popovers open to the right of the window
        if let screen = window.screen ?? chosenScreen() { region = region.intersection(topLeft(screen.frame)) }
        func s(_ r: NSRect) -> String { "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))" }
        let json = "{\"window\": \(window.windowNumber), \"title\": \"\(window.title)\", \"rect\": \"\(s(f))\", \"region\": \"\(s(region))\"}"
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
        if !isBackground { NSApp.activate() }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            if let w = NSApp.windows.first(where: { $0.isVisible && !before.contains(ObjectIdentifier($0)) && $0.styleMask.contains(.titled) }) { return w }
        }
        // The Settings scene did not open from an accessory app: host the same view in a plain window.
        guard let state = AppState.current else { return nil }
        let host = NSHostingController(rootView: SettingsView().environmentObject(state))
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        present(window)
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
        window.title = "Menu Bar"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(host.view.fittingSize)
        window.center()
        present(window)
        standalone = window
        return window
    }
}
