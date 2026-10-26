import Combine
import Foundation
import WMCore

/// A saved profile as the Auto profile settings list it: its name and the monitor set it was captured on.
struct AutoProfileEntry: Identifiable, Hashable {
    var id: UUID
    var name: String
    var monitorSetKey: String
}

/// Runs a saved profile on its own when the monitors change, the Mac wakes or the screen is unlocked.
///
/// Flow: DisplayWatcher reports an event (it already merges one burst into one call), the controller waits the
/// configured delay (a newer event restarts the wait), then `AutoProfileDecider` picks a profile and
/// `AppState.run(id:)` runs it, only when `AppState.canAct`. Nothing runs while the feature is off.
@MainActor
final class AutoProfileController: ObservableObject {
    static let shared = AutoProfileController()

    @Published private(set) var settings: AutoProfileSettings
    /// Saved profiles, for the mapping picker.
    @Published private(set) var entries: [AutoProfileEntry] = []
    /// The monitor set connected now (`DisplayMap.monitorSetKey`), empty before the first refresh.
    @Published private(set) var currentMonitorSetKey = ""
    @Published private(set) var currentMonitorCount = 0
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastRunName: String?

    private let fileStore: AutoProfileStore
    private let profileStore: ProfileStore
    private var watcher: DisplayWatcher?
    private var pending: Task<Void, Never>?
    private var pendingEvents: Set<AutoProfileEvent> = []

    init(fileStore: AutoProfileStore = AutoProfileStore(), profileStore: ProfileStore? = nil) {
        self.fileStore = fileStore
        self.profileStore = profileStore ?? ProfileStore()
        self.settings = fileStore.load()
    }

    // MARK: Lifecycle

    /// Starts listening for display changes, wake and unlock. Safe to call twice. Whether a run happens is decided
    /// by `settings.enabled` at event time, so turning the feature on or off needs no start or stop.
    func start() {
        refreshCurrent()
        refreshEntries()
        guard watcher == nil else { return }
        var created: DisplayWatcher?
        let new = DisplayWatcher { _, _, _ in
            // The handler runs on the main queue; read the triggers there, then hop to the main actor.
            let triggers = created?.lastTriggers ?? []
            Task { @MainActor in AutoProfileController.shared.schedule(triggers) }
        }
        created = new
        watcher = new
        new.start()
    }

    /// Stops listening and drops a run that is still waiting for its delay.
    func stop() {
        watcher?.stop()
        watcher = nil
        pending?.cancel()
        pending = nil
        pendingEvents = []
    }

    // MARK: Settings

    /// Changes the settings and saves them. Callers pass a closure that edits a copy.
    func update(_ change: (inout AutoProfileSettings) -> Void) {
        var copy = settings
        change(&copy)
        settings = copy
        do {
            try fileStore.save(copy)
        } catch {
            AppInfo.logger.error("Could not save auto profile settings: \(error.localizedDescription)")
        }
    }

    /// Re-reads the monitors and the saved profiles. The view calls it when it appears.
    func refresh() {
        refreshCurrent()
        refreshEntries()
    }

    var lastRunText: String {
        guard let lastRun, let lastRunName else { return "No automatic run yet" }
        return "Last automatic run: \(lastRunName), \(lastRun.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: Events

    /// Collapses the triggers of one burst into one pending decision. A newer event restarts the delay.
    private func schedule(_ triggers: DisplayWatcher.Trigger) {
        refreshCurrent()
        guard settings.enabled else { return }
        var events = pendingEvents
        if triggers.contains(.displays) { events.insert(.monitorChange) }
        if triggers.contains(.wake) { events.insert(.wake) }
        if triggers.contains(.unlock) { events.insert(.unlock) }
        guard !events.isEmpty else { return }
        pendingEvents = events
        pending?.cancel()
        let delay = settings.delaySeconds
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.fire(events)
        }
    }

    /// Decides after the delay and runs the chosen profile. The monitors are read again here, because they may
    /// have changed during the wait.
    private func fire(_ events: Set<AutoProfileEvent>) async {
        pendingEvents = []
        pending = nil
        refreshCurrent()
        let candidates = await loadCandidates()
        let now = Date()
        let key = currentMonitorSetKey
        // Events in a fixed order, so the same burst always picks the same event.
        for event in AutoProfileEvent.allCases where events.contains(event) {
            guard let id = AutoProfileDecider.decide(event: event, currentMonitorSetKey: key, settings: settings,
                                                     savedProfiles: candidates, lastRun: lastRun, now: now) else {
                continue
            }
            guard let state = AppState.current, state.canAct else {
                AppInfo.logger.notice("Auto profile skipped: the app cannot act now")
                return
            }
            lastRun = now
            lastRunName = entries.first { $0.id == id }?.name ?? "profile"
            state.run(id: id)
            return
        }
    }

    // MARK: Reading state

    private func refreshCurrent() {
        let displays = DisplayMap.current()
        currentMonitorSetKey = DisplayMap.monitorSetKey(displays)
        currentMonitorCount = displays.count
    }

    /// Reloads the picker list off the main thread.
    private func refreshEntries() {
        Task { [weak self] in
            guard let self else { return }
            self.entries = await self.loadEntries()
        }
    }

    private func loadEntries() async -> [AutoProfileEntry] {
        let store = profileStore
        return await Task.detached(priority: .utility) { () -> [AutoProfileEntry] in
            store.list().compactMap { summary -> AutoProfileEntry? in
                guard let profile = try? store.load(summary.id) else { return nil }
                return AutoProfileEntry(id: summary.id, name: summary.name, monitorSetKey: profile.monitorSetKey)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }

    private func loadCandidates() async -> [AutoProfileCandidate] {
        let loaded = await loadEntries()
        entries = loaded
        return loaded.map { AutoProfileCandidate(id: $0.id, monitorSetKey: $0.monitorSetKey) }
    }
}
