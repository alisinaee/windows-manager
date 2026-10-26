import SwiftUI

/// Long-lived helpers for the Spaces features (guard, pin rules, auto profile), started once at launch.
@MainActor
final class SpacesServices {
    static let shared = SpacesServices()

    let spaceGuard = SpaceGuardController()
    let pins = PinWatcher()
    let backups = BackupController()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        pins.reload()
        AutoProfileController.shared.start()
    }
}

/// Spaces: SkyLight health, Desktop order guard and pin rules.
struct SpacesSettingsTab: View {
    var body: some View {
        Form {
            SkyLightHealthView()
            SpaceGuardView(controller: SpacesServices.shared.spaceGuard)
            BackupSection(controller: SpacesServices.shared.backups)
            PinRulesSection(onChange: { SpacesServices.shared.pins.reload() })
        }
        .formStyle(.grouped)
    }
}

/// Automation: run a profile when the monitors change or the Mac wakes or unlocks.
struct AutomationSettingsTab: View {
    var body: some View {
        Form {
            AutoProfileView()
        }
        .formStyle(.grouped)
    }
}
