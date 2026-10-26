import AppKit
import Combine
import WMCore

/// Placeholder app state. `profiles` is replaced by the real profile store in P2.9.
@MainActor
final class AppState: ObservableObject {
    @Published var profiles: [String] = []
    @Published private(set) var isAccessibilityTrusted: Bool = AXPermission.isTrusted()

    private var pollTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    init() {
        // The user grants Accessibility in System Settings and comes back: re-check when we become active.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    /// Re-reads the permissions. Cheap and never shows a dialog.
    func refreshPermissions() {
        let trusted = AXPermission.isTrusted()
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
    }

    /// Shows the system Accessibility dialog, then checks once a second (up to a minute) until the grant lands.
    func requestAccessibility() {
        AXPermission.prompt()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refreshPermissions()
                if self.isAccessibilityTrusted { return }
            }
        }
    }
}
