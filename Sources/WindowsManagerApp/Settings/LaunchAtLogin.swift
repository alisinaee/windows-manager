import Foundation
import ServiceManagement

/// "Launch at login" backed by SMAppService.mainApp (macOS 13+). The system owns the registration,
/// so `isEnabled` is always read back from the service rather than stored.
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled: Bool
    /// Set when the last register/unregister call failed; shown under the toggle.
    @Published private(set) var errorText: String?

    init() {
        isEnabled = Self.currentStatusIsEnabled()
    }

    /// True when the user must approve the item in System Settings > General > Login Items.
    var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    func refresh() {
        isEnabled = Self.currentStatusIsEnabled()
    }

    func set(_ enabled: Bool) {
        errorText = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let action = enabled ? "enable" : "disable"
            errorText = "Could not \(action) launch at login: \(error.localizedDescription)"
        }
        refresh()
    }

    private static func currentStatusIsEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }
}
