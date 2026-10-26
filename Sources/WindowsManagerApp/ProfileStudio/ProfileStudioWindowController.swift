import AppKit
import SwiftUI

/// Owns the single shared "Profile Studio" window. The app is an accessory app (no Dock icon), so showing the
/// window also brings the app forward. The frame is remembered across launches.
@MainActor
final class ProfileStudioWindowController: NSObject, NSWindowDelegate {
    static let shared = ProfileStudioWindowController()

    /// Minimum content size (UI1 shell; the full design asks for 960x600 once the inspector exists).
    static let minSize = NSSize(width: 900, height: 600)

    private var window: NSWindow?
    private let model = ProfileStudioModel()

    /// Shows the studio (or brings the open one forward). With `profileID` it selects that profile.
    func show(profileID: UUID? = nil) {
        if let profileID { model.open(profileID: profileID) } else { model.reload() }
        if let window {
            present(window)
            return
        }
        let hosting = NSHostingController(rootView: ProfileStudioView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = model.windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minSize
        window.delegate = self
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        window.setFrameAutosaveName("ProfileStudio")
        self.window = window
        model.onTitleChange = { [weak window] title in window?.title = title }
        present(window)
    }

    private func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        resolveUnsaved { [weak sender] in sender?.close() }
    }

    /// True when quitting may go ahead now. Otherwise asks Save / Discard / Cancel and, after a save, replies to the pending terminate.
    func shouldTerminateNow() -> Bool {
        resolveUnsaved { NSApp.reply(toApplicationShouldTerminate: true) }
    }

    /// Returns true when there is nothing to ask (or the user discarded). On Save it returns false and runs `afterSave` once saved.
    private func resolveUnsaved(afterSave: @escaping () -> Void) -> Bool {
        guard model.hasUnsavedChanges else { return true }
        if let window { present(window) }
        let alert = NSAlert()
        alert.messageText = "Save changes to this profile?"
        alert.informativeText = "Your changes will be lost if you close without saving."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.saveThen(afterSave)
            return false
        case .alertSecondButtonReturn:
            model.leaveEdit()
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        model.onTitleChange = nil
        window = nil
    }
}
