import AppKit
import SwiftUI

/// Owns the single shared "Profile Studio" window. The app is an accessory app (no Dock icon), so showing the
/// window also brings the app forward. The frame is remembered across launches.
@MainActor
final class ProfileStudioWindowController: NSObject, NSWindowDelegate {
    static let shared = ProfileStudioWindowController()

    /// Minimum content size. The widest layout needs sidebar 200 + library 160 + map 320 + inspector 260 = 940.
    static let minSize = NSSize(width: 1000, height: 640)

    private var window: NSWindow?
    private let model = ProfileStudioModel()

    /// Shows the studio (or brings the open one forward). With `profileID` it selects that profile.
    func show(profileID: UUID? = nil) {
        DebugLog.log("studio", "window open")
        if let profileID { model.open(profileID: profileID) } else { model.reload() }
        if let window {
            present(window)
            return
        }
        let hosting = NSHostingController(rootView: ProfileStudioView(model: model))
        hosting.sizingOptions = []   // the window decides the size; the SwiftUI content never pushes it
        let window = NSWindow(contentViewController: hosting)
        window.title = model.windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minSize
        window.delegate = self
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        window.setFrameAutosaveName("ProfileStudio")
        clampToScreen(window)
        self.window = window
        model.onTitleChange = { [weak window] title in window?.title = title }
        present(window)
    }

    /// A frame restored from an older run may be smaller than the minimum or bigger/off the screen: fix it.
    private func clampToScreen(_ window: NSWindow) {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let minFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minSize)).size
        var frame = window.frame
        frame.size.width = min(max(frame.width, minFrame.width), max(visible.width, minFrame.width))
        frame.size.height = min(max(frame.height, minFrame.height), max(visible.height, minFrame.height))
        frame.origin.x = min(max(frame.minX, visible.minX), max(visible.maxX - frame.width, visible.minX))
        frame.origin.y = min(max(frame.minY, visible.minY), max(visible.maxY - frame.height, visible.minY))
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    private func present(_ window: NSWindow) {
        clampToScreen(window)
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
