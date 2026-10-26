import AppKit
import SwiftUI

/// Owns the "Set up Windows Manager" window. The app is an accessory app (no Dock icon), so showing the
/// window also brings the app forward. Completion is remembered in UserDefaults.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    /// UserDefaults key set once the user presses Finish.
    static let completedKey = "onboardingCompleted"

    static var isCompleted: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    private var window: NSWindow?

    /// Shows the window (or brings the open one forward) and activates the app.
    func show() {
        if let window {
            present(window)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView(onFinish: { [weak self] in self?.finish() }))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Set up Windows Manager"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        window?.close()
    }

    // A fresh window (back on step 1) the next time it is opened.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window = nil
    }
}
