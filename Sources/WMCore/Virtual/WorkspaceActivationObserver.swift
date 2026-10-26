import AppKit
import Foundation

/// Thin NSWorkspace observer: reports every app activation (Cmd+Tab, Dock click) to a handler.
/// The handler owns the follower and the switcher; this type holds no logic.
public final class WorkspaceActivationObserver {
    private var token: NSObjectProtocol?
    private let handler: (WorkspaceActivationEvent) -> Void

    public init(handler: @escaping (WorkspaceActivationEvent) -> Void) {
        self.handler = handler
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [handler] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            handler(WorkspaceActivationEvent(bundleID: app?.bundleIdentifier))
        }
    }

    public func stop() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }

    deinit { stop() }
}
