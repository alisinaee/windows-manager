import AppKit
import Foundation
import WMCore

/// State of the Debug panel. Runs the live scenarios through `DebugTestRunner` and turns its events into
/// published values on the main actor.
@MainActor
final class DebugPanelModel: ObservableObject {
    /// Scenario whose live view is shown (the running one, or the last one run).
    @Published var focus: String?
    @Published private(set) var running: String?
    @Published private(set) var isRunningAll = false
    @Published private(set) var phase = ""
    @Published private(set) var steps: [DebugStepRow] = []
    @Published private(set) var checks: [DebugCheck] = []
    @Published private(set) var results: [String: DebugRunResult] = [:]
    /// Status of the last run per scenario id, also from the previous app session (debug-run.json).
    @Published private(set) var lastStatus: [String: DebugRunStatus] = DebugRunnerRegistry.lastStatuses()
    @Published private(set) var fixtureMessage = ""
    @Published private(set) var copyMessage = ""

    private let store: ProfileStore
    private let onProfilesChanged: () -> Void
    private var queue: [DebugRunnerEntry] = []

    init(store: ProfileStore, onProfilesChanged: @escaping () -> Void) {
        self.store = store
        self.onProfilesChanged = onProfilesChanged
    }

    var isBusy: Bool { running != nil || isRunningAll }

    // MARK: Actions

    func installFixtures() {
        guard !isBusy else { return }
        do {
            let profiles = try DebugTestRunner.installFixtureProfiles(into: store)
            _ = try DebugFixtures.installPowerUserFixtures(into: store)
            fixtureMessage = "Installed \(profiles.count + DebugFixtures.scenarios.count) fixture profile(s)"
            onProfilesChanged()
        } catch {
            fixtureMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    func run(_ scenario: DebugRunnerEntry) {
        guard !isBusy else { return }
        queue = [scenario]
        startNext()
    }

    func runAll() {
        guard !isBusy else { return }
        queue = DebugRunnerRegistry.entries
        isRunningAll = true
        startNext()
    }

    /// Runs the next queued scenario, one at a time, so the live view always shows a single run.
    private func startNext() {
        guard !queue.isEmpty else {
            isRunningAll = false
            running = nil
            return
        }
        let scenario = queue.removeFirst()
        running = scenario.id
        focus = scenario.id
        phase = "Starting \(scenario.title)…"
        steps = []
        checks = []
        copyMessage = ""

        let runner = DebugTestRunner(store: store)
        let sink: @Sendable (DebugEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        Task { [weak self] in
            let result = await runner.run(scenario, onEvent: sink)
            guard let self else { return }
            self.results[scenario.id] = result
            self.lastStatus[scenario.id] = result.status
            self.running = nil
            self.phase = result.status.rawValue.capitalized
            self.startNext()
        }
    }

    private func handle(_ event: DebugEvent) {
        switch event {
        case .phase(let text):
            phase = text
        case .step(let row):
            if let index = steps.firstIndex(where: { $0.id == row.id }) {
                steps[index] = row
            } else {
                steps.append(row)
            }
        case .check(let check):
            if let index = checks.firstIndex(where: { $0.id == check.id }) {
                checks[index] = check
            } else {
                checks.append(check)
            }
        case .log:
            break
        }
    }

    // MARK: Results

    /// Results of the runs so far, as JSON in the same spirit as the lab results files.
    func resultJSON() -> String {
        let items: [[String: Any]] = DebugRunnerRegistry.entries.map(\.id).compactMap { id in
            guard let result = results[id] else { return nil }
            return [
                "scenario": id,
                "status": result.status.rawValue,
                "passed": result.passed,
                "checks": result.checks.map { check -> [String: Any] in
                    ["id": "\(check.id)", "name": check.name, "passed": check.passed, "detail": check.detail]
                },
                "log": result.log,
            ]
        }
        let root: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "passed": !items.isEmpty && items.allSatisfy { ($0["passed"] as? Bool) == true },
            "results": items,
        ]
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    func copyResult() {
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(resultJSON(), forType: .string)
        copyMessage = copied ? "Copied result JSON" : "Copy failed"
    }
}
