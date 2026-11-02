import CoreGraphics
import Foundation
import Testing
@testable import WMCore

private final class NoAX: AXProvider, @unchecked Sendable {
    func roots(bundleID: String) -> [any AXNode] { [] }
    func menuBar(bundleID: String) -> (any AXNode)? { nil }
    func sendKey(_ combo: KeyCombo) throws {}
    func typeText(_ text: String) throws {}
}

private final class LogProcess: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var log: [String] { lock.withLock { entries } }
    func runShell(_ c: String, waitForExit: Bool, timeout: TimeInterval) async throws -> ShellResult {
        lock.withLock { entries.append(c) }
        return ShellResult(exitCode: c.hasPrefix("fail") ? 1 : 0, output: "")
    }
    func runShortcut(_ n: String, timeout: TimeInterval) async throws -> ShellResult { ShellResult(exitCode: 0) }
    func launchApp(bundleID: String, timeout: TimeInterval) async throws {}
    func openURL(_ url: String) async throws {}
}

private struct NoWait: ActionClock {
    func now() -> TimeInterval { 0 }
    func sleep(_ seconds: TimeInterval) async throws {}
}

private func action(_ name: String, _ phase: ActionPhase, _ commands: [String], enabled: Bool = true) -> ProfileAction {
    ProfileAction(name: name, phase: phase, steps: commands.map { .shell(command: $0) }, enabled: enabled)
}

@MainActor
@Suite struct ProfileActionsTests {
    typealias F = RestoreFixtures

    private func setup(actions: [ProfileAction]) -> (RestoreEngine, FakeRestoreEnvironment, LogProcess, Profile) {
        var profile = F.profile([F.snap(1, F.chrome)])
        profile.actions = actions
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome)])])
        let process = LogProcess()
        let engine = RestoreEngine(environment: env,
                                   actionRunner: ActionRunner(ax: NoAX(), process: process, clock: NoWait()))
        return (engine, env, process, profile)
    }

    // MARK: Decoding

    @Test func oldProfileWithoutActionsKeyLoads() throws {
        var profile = F.profile([F.snap(1, F.chrome)])
        profile.actions = [action("A", .afterRestore, ["echo"])]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(F.profile([F.snap(1, F.chrome)]))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"actions\""))   // an old file looks exactly like this
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Profile.self, from: data).actions.isEmpty)

        let withActions = try encoder.encode(profile)
        #expect(try decoder.decode(Profile.self, from: withActions).actions == profile.actions)
    }

    // MARK: Ordering

    @Test func beforeThenWindowsThenAfter() async {
        let (engine, env, process, profile) = setup(actions: [
            action("late", .afterRestore, ["after1"]),
            action("early", .beforeRestore, ["before1", "before2"]),
            action("off", .beforeRestore, ["never"], enabled: false),
        ])
        var stages: [String] = []
        let report = await engine.run(profile) { event in
            switch event {
            case .actionStarted(let name, _, _): stages.append("start:\(name)")
            case .actionFinished(let name, _, _): stages.append("end:\(name)")
            case .scanning: stages.append("scan")
            case .finished: stages.append("finished")
            default: break
            }
        }
        #expect(stages == ["start:early", "end:early", "scan", "start:late", "end:late", "finished"])
        #expect(process.log == ["before1", "before2", "after1"])
        #expect(env.count("scan") >= 1)
        let records = report.actions ?? []
        #expect(records.map(\.name) == ["early", "off", "late"] || records.map(\.name) == ["off", "early", "late"])
        #expect(records.first { $0.name == "off" }?.skipped == true)
        #expect(report.isClean)
    }

    @Test func failedActionDoesNotAbortRestore() async {
        var profile = F.profile([F.snap(1, F.chrome, frame: CGRect(x: 10, y: 10, width: 300, height: 300))])
        profile.actions = [action("bad", .beforeRestore, ["fail now"]), action("good", .afterRestore, ["ok"])]
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome)])])
        let process = LogProcess()
        let engine = RestoreEngine(environment: env, actionRunner: ActionRunner(ax: NoAX(), process: process, clock: NoWait()))
        let report = await engine.run(profile)
        #expect(env.actions.contains("setFrame:101"))          // windows were still restored
        #expect(process.log == ["fail now", "ok"])             // and the later action still ran
        #expect(report.actions?.first?.failed == true)
        #expect(report.warnings.contains { $0.contains("Action \"bad\" failed at step 1") })
        #expect(!report.isClean)
    }

    @Test func dryRunAndPlanListActionsWithoutRunningThem() async {
        let (engine, _, process, profile) = setup(actions: [action("a", .beforeRestore, ["x"]), action("b", .afterRestore, ["y"])])
        let report = await engine.run(profile, dryRun: true)
        #expect(process.log.isEmpty)
        #expect(report.actions?.map(\.name) == ["a", "b"])
        #expect(report.actions?.allSatisfy { $0.skipped && $0.note == "dry run" } == true)

        let plan = await engine.preview(profile: profile)
        #expect(plan.actions.map(\.name) == ["a", "b"])
        #expect(process.log.isEmpty)
    }

    @Test func partialScopeRunsNoActions() async {
        let (engine, _, process, profile) = setup(actions: [action("a", .beforeRestore, ["x"])])
        let report = await engine.run(profile, scope: RestoreScope(apps: [F.chrome.bundleID ?? "x"]))
        #expect(process.log.isEmpty)
        #expect(report.actions == nil)
    }
}
