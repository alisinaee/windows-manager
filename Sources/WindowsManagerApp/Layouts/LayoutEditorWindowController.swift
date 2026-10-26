import AppKit
import SwiftUI

/// Owns the "Layouts" window. The app is an accessory app (no Dock icon), so showing the window also
/// brings the app forward.
@MainActor
final class LayoutEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = LayoutEditorWindowController()

    private var window: NSWindow?

    /// Shows the window (or brings the open one forward) and activates the app.
    func show() {
        if let window {
            present(window)
            return
        }
        let hosting = NSHostingController(rootView: LayoutEditorView(model: LayoutEditorModel()))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Layouts"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
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

    // A fresh editor (current displays and apps) the next time it is opened.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window = nil
    }
}
