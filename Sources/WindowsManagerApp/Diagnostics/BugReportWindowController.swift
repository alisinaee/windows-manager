import AppKit
import SwiftUI

@MainActor
final class BugReportWindowController: NSObject, NSWindowDelegate {
    static let shared = BugReportWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: BugReportView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "Report a Bug"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 560, height: 600))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}
