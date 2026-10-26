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

    /// The repair waiting for the user's confirmation. Setting it shows the alert in `SpaceGuardView`.
    @Published var pendingRepair: RepairPlan?
    /// Text of `pendingRepair` for the alert.
    @Published private(set) var repairSummary: String = ""
    @Published private(set) var isRepairing = false
    /// Set when a drift was reported and auto-fix is on: a fix is available, but never run automatically.
    @Published private(set) var fixAvailable = false

    static let defaultsKey = "spaceGuard.settings"

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

    /// Fix button, step 1. Read only: reads com.apple.spaces and the live Spaces, builds the repair plan and
    /// publishes it as `pendingRepair`. Nothing is changed until `confirmFix()`.
    func prepareFix() {
        guard let report, !report.drifts.isEmpty else {
            status = "There is no drift to fix."
            return
        }
        do {
            let config = try SpaceOrderFile.readDomain()
            let live = try SpaceReader.displays()
            let plan = SpaceOrderRepair.plan(report: report, expected: settings.expectedOrder ?? [],
                                             storedConfig: config, liveDisplays: live)
            guard plan.isRunnable else {
                status = plan.summary
                pendingRepair = nil
                return
            }
            repairSummary = plan.summary
            pendingRepair = plan
        } catch {
            status = "Could not prepare the fix: \(error.localizedDescription)"
        }
    }

    /// Fix button, step 2: only the confirmation alert calls this. Runs the repair on a background task.
    func confirmFix() {
        guard let plan = pendingRepair, !isRepairing else { return }
        pendingRepair = nil
        isRepairing = true
        status = "Repairing the Space order ..."
        Task { [weak self] in
            let message: String
            do {
                let result = try await Task.detached {
                    try await SpaceOrderRepair.run(plan, confirmed: true, deps: .live())
                }.value
                switch result.outcome {
                case .repaired:
                    message = result.message
                case .needsAttention(_, let instruction):
                    message = instruction
                }
            } catch {
                message = error.localizedDescription
            }
            guard let self else { return }
            self.isRepairing = false
            self.status = message
            self.checkNow()
            self.status = message
        }
    }

    func cancelFix() {
        pendingRepair = nil
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

    /// Called once per new confirmed drift. The auto-fix option only badges "Fix available"; the repair always
    /// needs the user to press Fix and confirm.
    private func handleDrift(_ drift: SpaceGuardReport) {
        report = drift
        lastChecked = watcher?.lastChecked
        refreshStatusText()
        if settings.autoFix { fixAvailable = true }
    }

    private func refreshStatusText() {
        if report?.isClean ?? true { fixAvailable = false }
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
