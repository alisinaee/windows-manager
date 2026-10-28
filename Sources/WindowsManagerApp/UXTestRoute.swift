import AppKit
import WMCore

/// `windowsmanager://open?...` for UX capture. Active only with env WM_UX_TEST=1 (otherwise ignored).
@MainActor
enum UXTestRoute {
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

    static func run(_ route: UXOpenRoute) async {
        if let a = route.appearance { NSApp.appearance = NSAppearance(named: a == .dark ? .darkAqua : .aqua) }
        AppState.current?.reloadProfiles()
        var target: NSWindow?
        switch route.section {
        case .studio:
            ProfileStudioModel.uxInspectorTab = route.inspectorTab.map {
                switch $0 { case .inspector: return .inspector; case .options: return .options; case .launch: return .launchOrder }
            }
            ProfileStudioWindowController.shared.show()
            if let model = ProfileStudioModel.uxCurrent() {
                await model.uxApply(profile: route.profile, mode: route.mode, sheet: route.sheet)
            }
            target = NSApp.windows.first { ProfileStudioModel.isStudioWindow($0) }
        case .settings:
            NSApp.activate()
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            try? await Task.sleep(for: .milliseconds(300))
            target = NSApp.keyWindow
        case .onboarding:
            OnboardingWindowController.shared.show()
            target = NSApp.keyWindow
        case .debug:
            if let state = AppState.current {
                DebugWindowController.shared.show(store: state.store) { [weak state] in state?.reloadProfiles() }
            }
            target = NSApp.keyWindow
        case .popover:
            // Best effort: click the status item button of the MenuBarExtra.
            for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
                if let button = findStatusButton(in: window.contentView) { button.performClick(nil); break }
            }
        }
        if let size = route.size, let window = target ?? NSApp.keyWindow {
            var frame = window.frame
            let content = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
            frame.origin.y += frame.height - content.height
            frame.size = content
            window.setFrame(frame, display: true)
        }
    }

    private static func findStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let b = view as? NSStatusBarButton { return b }
        for sub in view.subviews { if let b = findStatusButton(in: sub) { return b } }
        return nil
    }
}
