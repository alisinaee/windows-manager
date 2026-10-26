import Foundation
import SwiftUI
import WMCore

/// App side of the Space guard (P3.4): owns the settings, the drift watcher and the report shown in Settings.
/// It never changes the Space order or the Dock's "mru-spaces" setting by itself.
@MainActor
final class SpaceGuardController: ObservableObject {
    @Published private(set) var settings: SpaceGuardSettings
    @Published private(set) var report: SpaceGuardReport?
    @Published private(set) var lastChecked: Date?
    /// One line for the status row: why nothing is watched, what the last check found, or what Fix did.
    @Published private(set) var status: String = ""

    static let defaultsKey = "spaceGuard.settings"
    static let fixUnavailableText = "Fix is available from spaceslab order-file apply"

    private let defaults: UserDefaults
    private var watcher: DriftWatcher?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = Self.loadSettings(from: defaults)
        if settings.watchEnabled { startWatching() }
        refreshStatusText()
    }

    // MARK: Settings

    func setWatch(_ on: Bool) {
        settings.watchEnabled = on
        saveSettings()
        if on { startWatching() } else { stopWatching() }
    }

    func setAutoFix(_ on: Bool) {
        settings.autoFix = on
        saveSettings()
    }

    /// Stores the live order as the expected order.
    func setExpectedFromCurrentOrder() {
        do {
            let order = try DriftWatcher.liveReader()
            guard !order.isEmpty else {
                status = "No Spaces were read, so nothing was saved as expected."
                return
            }
            settings.setExpected(order, source: "Current order")
            saveSettings()
            watcher?.expected = order
            report = nil
            refreshStatusText()
        } catch {
            status = "Could not read the Spaces: \(error.localizedDescription)"
        }
    }

    /// Stores a captured profile's Space order as the expected order.
    func setExpected(from profile: Profile) {
        let order = profile.displays.map { DisplaySpaceOrder(profile: profile, displayUUID: $0.uuid) }
            .filter { !$0.slots.isEmpty }
        guard !order.isEmpty else {
            status = "Profile \"\(profile.name)\" has no Space order to expect."
            return
        }
        settings.setExpected(order, source: "Profile \(profile.name)")
        saveSettings()
        watcher?.expected = order
        report = nil
        refreshStatusText()
    }

    // MARK: Checking

    /// Reads the order now and updates the report (also used by a "Check now" button).
    func checkNow() {
        guard settings.hasExpectedOrder else {
            status = "Set the current order as expected first."
            return
        }
        let watch = watcher ?? makeWatcher()
        watcher = watch
        watch.expected = settings.expectedOrder ?? []
        if watch.poll() == nil {
            status = watch.lastError.map { "Could not read the Spaces: \($0)" } ?? "Could not read the Spaces."
            return
        }
        report = watch.lastReport
        lastChecked = watch.lastChecked
        refreshStatusText()
    }

    /// Fix button. The existing rebuild (`SpaceOrderFile.reordered` with the apply steps of `spaceslab order-file apply`)
    /// writes the com.apple.spaces preference and restarts the Dock, and lives in the spaceslab command target. The app
    /// cannot call it safely yet, so this only says where to run it. The rebuild starts at `report.fixPlan.fromSlot`.
    func fix() {
        if let plan = report?.fixPlan {
            status = "\(Self.fixUnavailableText). \(plan.description)"
        } else {
            status = Self.fixUnavailableText
        }
    }

    // MARK: Private

    private func startWatching() {
        guard settings.hasExpectedOrder else {
            refreshStatusText()
            return
        }
        stopWatching()
        let watch = makeWatcher()
        watcher = watch
        watch.start()
        refreshStatusText()
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    private func makeWatcher() -> DriftWatcher {
        DriftWatcher(expected: settings.expectedOrder ?? []) { [weak self] drift in
            MainActor.assumeIsolated { self?.handleDrift(drift) }
        }
    }

    /// Called once per new confirmed drift. Auto-fix only asks for the fix, which for now only says where to run it.
    private func handleDrift(_ drift: SpaceGuardReport) {
        report = drift
        lastChecked = watcher?.lastChecked
        if settings.autoFix { fix() } else { refreshStatusText() }
    }

    private func refreshStatusText() {
        if !settings.watchEnabled {
            status = "Watching is off."
        } else if !settings.hasExpectedOrder {
            status = "Set the current order as expected to start watching."
        } else if let report, report.isClean {
            status = "Space order matches the expected order."
        } else if report != nil {
            status = "Space order differs from the expected order."
        } else {
            status = "Watching. No check yet."
        }
    }

    private static func loadSettings(from defaults: UserDefaults) -> SpaceGuardSettings {
        do {
            guard let data = defaults.data(forKey: defaultsKey) else { return SpaceGuardSettings() }
            return try JSONDecoder().decode(SpaceGuardSettings.self, from: data)
        } catch {
            return SpaceGuardSettings()
        }
    }

    private func saveSettings() {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Self.defaultsKey)
        } catch {
            status = "Could not save Space guard settings: \(error.localizedDescription)"
        }
    }
}
