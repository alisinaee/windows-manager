import AppKit
import SwiftUI
import WMCore

/// Owns the single shared Debug window. It opens while Debug mode is on and closes when it is turned off.
/// Closing it with the red button also reports back, so the menu toggle follows the window.
@MainActor
final class DebugWindowController: NSObject, NSWindowDelegate {
    static let shared = DebugWindowController()

    /// Called when the user closes the window (not when `close()` runs), so the app can turn Debug mode off.
    var onClose: (() -> Void)?

    private var window: NSWindow?
    private var model: DebugPanelModel?

    /// Shows the panel, or brings the open one forward.
    func show(store: ProfileStore, onProfilesChanged: @escaping () -> Void) {
        if model == nil {
            model = DebugPanelModel(store: store, onProfilesChanged: onProfilesChanged)
        }
        if let window {
            present(window)
            return
        }
        guard let model else { return }
        let hosting = NSHostingController(rootView: DebugPanel(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Debug Tests"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 420)
        window.delegate = self
        window.setContentSize(NSSize(width: 560, height: 680))
        window.center()
        window.setFrameAutosaveName("DebugTests")
        self.window = window
        present(window)
    }

    /// Closes the panel without reporting back (used when Debug mode is turned off).
    func close() {
        let callback = onClose
        onClose = nil
        window?.close()
        onClose = callback
    }

    private func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window = nil
        onClose?()
    }
}
