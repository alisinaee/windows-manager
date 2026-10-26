import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// The fake environment, with a launch answer per app and a hook that runs after each launch call.
@MainActor
final class SequenceEnvironment: RestoreEnvironment {
    let base: FakeRestoreEnvironment
    /// App name -> status; apps not listed launch fine.
    var statuses: [String: LaunchResult.Status] = [:]
    var afterLaunch: ((Int) -> Void)?
    private(set) var requests: [[LaunchRequest]] = []

    init(scans: [WorkspaceScan]) { base = FakeRestoreEnvironment(scans: scans) }

    func scan() async -> WorkspaceScan { await base.scan() }

    func launchAll(_ requests: [LaunchRequest]) async -> [LaunchResult] {
        self.requests.append(requests)
        _ = await base.launchAll(requests)
        let results = requests.map {
            LaunchResult(app: $0.app, status: statuses[$0.app.name] ?? .launched, windowCount: $0.minWindows)
        }
        afterLaunch?(self.requests.count)
        return results
    }

    func element(for target: RestoreTarget) async -> WindowHandle? { base.element(for: target) }
    func setFrame(_ handle: WindowHandle, to frame: CGRect) async -> RestoreActionResult { await base.setFrame(handle, to: frame) }
    func setFullScreen(_ handle: WindowHandle, _ on: Bool, timeout: TimeInterval) async -> RestoreActionResult {
        await base.setFullScreen(handle, on, timeout: timeout)
    }
    func minimize(_ handle: WindowHandle) async -> RestoreActionResult { await base.minimize(handle) }
    func unminimize(_ handle: WindowHandle) async -> RestoreActionResult { await base.unminimize(handle) }
    func raise(_ handle: WindowHandle, app: AppRef) async -> RestoreActionResult { await base.raise(handle, app: app) }
    func moveToDesktop(windowID: UInt32, spaceID: UInt64) async -> RestoreActionResult {
        await base.moveToDesktop(windowID: windowID, spaceID: spaceID)
    }
    func hideApp(pid: Int32, app: AppRef) async -> RestoreActionResult { await base.hideApp(pid: pid, app: app) }
    func frameOf(_ handle: WindowHandle) async -> CGRect? { base.frameOf(handle) }
    func sleep(_ seconds: TimeInterval) async { await base.sleep(seconds) }
}

@MainActor
@Suite struct RestoreLaunchSequenceTests {
    typealias F = RestoreFixtures

    /// Chrome, Slack and Safari, one window each, none of them running; after launching they exist in place.
    static func threeApps(plan: LaunchPlan?) -> (Profile, [WorkspaceScan]) {
        var profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.slack), F.snap(3, F.safari)])
        profile.launchPlan = plan
        let after = F.scan([F.live(101, F.chrome), F.live(102, F.slack), F.live(103, F.safari)])
        return (profile, [F.scan([]), after])
    }

    static func item(_ app: AppRef, delay: TimeInterval = 0, timeout: TimeInterval? = nil, wait: LaunchWait = .windows,
                     enabled: Bool = true, launchOnly: Bool = false) -> LaunchItem {
        LaunchItem(app: app, enabled: enabled, wait: wait, delayAfter: delay, timeout: timeout, withoutWindows: launchOnly)
    }

    // MARK: Sequential

    @Test func sequentialLaunchesOneAtATimeInOrderAndSleepsTheDelays() async {
        let (profile, scans) = Self.threeApps(plan: LaunchPlan(mode: .sequential, items: [
            Self.item(F.slack, delay: 2), Self.item(F.safari, delay: 3, timeout: 30), Self.item(F.chrome, delay: 4),
        ]))
        let env = SequenceEnvironment(scans: scans)
        let report = await RestoreEngine(environment: env).run(profile)

        #expect(env.base.calls.filter { $0.hasPrefix("launch:") } == ["launch:Slack", "launch:Safari", "launch:Google Chrome"])
        #expect(env.requests.allSatisfy { $0.count == 1 })
        #expect(env.requests.map { $0[0].delayAfter } == [2, 3, 4])
        #expect(env.requests[1][0].options?.timeout == 30)
        #expect(env.requests[0][0].options?.timeout == LaunchOptions.defaultTimeout)
        // The delay after the last app is pointless and skipped.
        #expect(env.base.sleeps == [2, 3])
        #expect(report.steps.filter { $0.phase == .launch }.map(\.app) == ["Slack", "Safari", "Google Chrome"])
        #expect(report.steps.allSatisfy { $0.status.isDone })
        #expect(report.launched.count == 3)
    }

    @Test func appsOutsideThePlanLaunchAfterTheListedOnesInProfileOrder() async {
        let (profile, scans) = Self.threeApps(plan: LaunchPlan(mode: .sequential, items: [Self.item(F.safari)]))
        let env = SequenceEnvironment(scans: scans)
        _ = await RestoreEngine(environment: env).run(profile)
        #expect(env.base.calls.filter { $0.hasPrefix("launch:") } == ["launch:Safari", "launch:Google Chrome", "launch:Slack"])
    }

    @Test func noDelayAfterAnAppThatWasAlreadyRunning() async {
        let (profile, scans) = Self.threeApps(plan: LaunchPlan(mode: .sequential, items: [
            Self.item(F.slack, delay: 2), Self.item(F.safari, delay: 3), Self.item(F.chrome),
        ]))
        let env = SequenceEnvironment(scans: scans)
        env.statuses["Slack"] = .alreadyRunning
        let report = await RestoreEngine(environment: env).run(profile)
        #expect(env.base.sleeps == [3])
        #expect(report.steps.first { $0.app == "Slack" }?.status == .skipped("already running"))
    }

    @Test func aFailedLaunchIsAFailedStepAndTheSequenceContinues() async {
        let (profile, scans) = Self.threeApps(plan: LaunchPlan(mode: .sequential, items: [
            Self.item(F.slack), Self.item(F.safari), Self.item(F.chrome),
        ]))
        let env = SequenceEnvironment(scans: scans)
        env.statuses["Slack"] = .timedOut
        env.statuses["Safari"] = .failed("boom")
        let report = await RestoreEngine(environment: env).run(profile)
        #expect(env.requests.count == 3)
        let launches = report.steps.filter { $0.phase == .launch }
        #expect(launches.map(\.status.isDone) == [false, false, true])
        #expect(report.unmatched.isEmpty || report.unmatched.allSatisfy { !$0.reason.isEmpty })
    }

    @Test func appReadyWaitsForNoWindows() async {
        let (profile, scans) = Self.threeApps(plan: LaunchPlan(mode: .sequential, items: [
            Self.item(F.slack, wait: .appReady), Self.item(F.safari),
        ]))
        let env = SequenceEnvironment(scans: scans)
        _ = await RestoreEngine(environment: env).run(profile)
        #expect(env.requests[0][0].minWindows == 0)
        #expect(env.requests[0][0].options?.minWindows == 0)
        #expect(env.requests[1][0].minWindows == 1)
    }

    @Test func cancellationBetweenAppsSkipsTheRest() async {
        let (profile, scans) = Self.threeApps(plan: LaunchPlan(mode: .sequential, items: [
            Self.item(F.slack, delay: 5), Self.item(F.safari), Self.item(F.chrome),
        ]))
        let env = SequenceEnvironment(scans: scans)
        let box = TaskBox()
        env.afterLaunch = { _ in box.task?.cancel() }
        let engine = RestoreEngine(environment: env)
        box.task = Task { await engine.run(profile) }
        let report = await box.task!.value

        #expect(env.requests.count == 1)
        #expect(report.cancelled)
        #expect(env.base.sleeps.isEmpty)
        let launches = report.steps.filter { $0.phase == .launch }
        #expect(launches.map(\.app) == ["Slack", "Safari", "Google Chrome"])
        #expect(launches[0].status.isDone)
        #expect(launches[1].status == .skipped("cancelled") && launches[2].status == .skipped("cancelled"))
    }

    // MARK: Parallel and nil

    @Test func parallelAndNilPlansKeepTodaysSingleBatch() async {
        for plan in [nil, LaunchPlan(mode: .parallel, items: [Self.item(F.slack, delay: 9)])] {
            let (profile, scans) = Self.threeApps(plan: plan)
            let env = SequenceEnvironment(scans: scans)
            let report = await RestoreEngine(environment: env).run(profile)
            #expect(env.requests.count == 1)
            #expect(env.requests[0].map(\.app.name).sorted() == ["Google Chrome", "Safari", "Slack"])
            #expect(env.requests[0].allSatisfy { $0.options == nil && $0.delayAfter == 0 })
            #expect(env.base.sleeps.isEmpty)
            #expect(report.steps.filter { $0.phase == .launch }.count == 3)
        }
    }

    // MARK: Launch-only

    @Test func launchOnlyAppGetsAZeroWindowLaunchAndIsNotHidden() async {
        var profile = F.profile([F.snap(1, F.chrome)], options: ProfileOptions(otherApps: .hide))
        profile.launchPlan = LaunchPlan(mode: .sequential, items: [Self.item(F.notes, launchOnly: true)])

        // Notes is not running: launch with 0 windows, never counted as unmatched.
        let closed = F.scan([F.live(101, F.chrome), F.live(105, F.mail)])
        let plan = RestoreEngine(environment: FakeRestoreEnvironment(scans: [closed])).planPreview(profile, closed)
        #expect(plan.steps(in: .launch) == [.launch(app: F.notes, windowCount: 0)])
        #expect(plan.unmatched.isEmpty)
        #expect(plan.steps.contains(.hideApp(app: F.mail, pid: 1105)))

        // Notes is running with a window: not launched again, and the other-apps hide leaves it alone.
        let open = F.scan([F.live(101, F.chrome), F.live(105, F.mail), F.live(106, F.notes)])
        let openPlan = RestoreEngine(environment: FakeRestoreEnvironment(scans: [open])).planPreview(profile, open)
        #expect(openPlan.steps(in: .launch).isEmpty)
        let hidden = openPlan.steps.compactMap { step -> String? in
            if case .hideApp(let app, _) = step { return app.name } else { return nil }
        }
        #expect(hidden == ["Mail"])
    }

    @Test func launchOnlyAppRunsThroughTheEngineWithoutWaitingForWindows() async {
        var profile = F.profile([F.snap(1, F.chrome)])
        profile.launchPlan = LaunchPlan(mode: .sequential, items: [Self.item(F.notes, delay: 1, launchOnly: true)])
        let scan = F.scan([F.live(101, F.chrome)])
        let env = SequenceEnvironment(scans: [scan])
        let report = await RestoreEngine(environment: env).run(profile)
        #expect(env.requests.count == 1)
        #expect(env.requests[0][0].app == F.notes && env.requests[0][0].minWindows == 0)
        #expect(report.steps.filter { $0.phase == .launch }.count == 1)
    }

    @Test func aSwitchedOffAppIsNotLaunched() async {
        let (profile, _) = Self.threeApps(plan: LaunchPlan(mode: .sequential, items: [
            Self.item(F.slack, enabled: false), Self.item(F.safari),
        ]))
        let scans = [F.scan([]), F.scan([F.live(101, F.chrome), F.live(103, F.safari)])]
        let env = SequenceEnvironment(scans: scans)
        let report = await RestoreEngine(environment: env).run(profile)
        #expect(!env.requests.flatMap { $0 }.contains { $0.app == F.slack })
        #expect(report.unmatched.contains { $0.app == F.slack && $0.reason == "launching this app is switched off in Launch order" })
    }

    // MARK: Desktops

    @Test func perProfileAddMissingDesktopsPlansTheAddStep() async {
        var profile = RestoreAddDesktopsTests.chromeOnThreeSlackOnTwo()
        let scan = RestoreAddDesktopsTests.liveChromeAndSlack(desktopsOnA: 2)

        let off = RestoreEngine(environment: FakeRestoreEnvironment(scans: [scan]))
        #expect(!(await off.preview(profile: profile)).steps.contains { $0.kind == "addDesktop" })

        profile.options.addMissingDesktops = true
        let plan = await off.preview(profile: profile)
        #expect(plan.steps.first == .addDesktop(display: F.displayA(), count: 1))

        // Run: the adder is called although the engine-level flag is off.
        let adder = FakeDesktopAdder(count: 2)
        let env = FakeRestoreEnvironment(scans: [scan, RestoreAddDesktopsTests.liveChromeAndSlack(desktopsOnA: 3)])
        _ = await RestoreEngine(environment: env, desktopAdder: adder).run(profile)
        #expect(adder.calls == 1)
    }

    @Test func engineLevelFlagStillEnablesAddingWithoutTheProfileOption() async {
        let profile = RestoreAddDesktopsTests.chromeOnThreeSlackOnTwo()
        var configuration = RestoreEngine.Configuration()
        configuration.addMissingDesktops = true
        let scan = RestoreAddDesktopsTests.liveChromeAndSlack(desktopsOnA: 2)
        let engine = RestoreEngine(environment: FakeRestoreEnvironment(scans: [scan]), configuration: configuration)
        #expect((await engine.preview(profile: profile)).steps.contains { $0.kind == "addDesktop" })
    }

    // MARK: Preview

    @Test func previewOnlyScans() async {
        var profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.slack)], options: ProfileOptions(otherApps: .hide))
        profile.launchPlan = LaunchPlan(mode: .sequential, items: [Self.item(F.slack, delay: 3)])
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome, frame: F.defaultFrame.offsetBy(dx: 50, dy: 0)),
                                                         F.live(105, F.mail)])])
        let plan = await RestoreEngine(environment: env).preview(profile: profile)
        #expect(env.calls == ["scan"])
        #expect(plan.steps(in: .launch) == [.launch(app: F.slack, windowCount: 1)])
        #expect(plan.steps.contains { $0.kind == "setFrame" })
    }

    // MARK: Stage Manager

    @Test func windowsPossiblyInTheStageStripAreReported() async {
        let profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.chrome, index: 1)])
        var parked = F.live(101, F.chrome)
        parked.isInStageStrip = true
        var scan = F.scan([parked])
        scan.stageManagerOn = true
        let plan = await RestoreEngine(environment: FakeRestoreEnvironment(scans: [scan])).preview(profile: profile)
        #expect(plan.unmatched.isEmpty)
        #expect(plan.possiblyParked == [F.sid(2)])
        #expect(plan.warnings.contains { $0.contains("may be in the strip") })

        // Stage Manager off: the same shortage is a plain unmatched window.
        scan.stageManagerOn = false
        let off = await RestoreEngine(environment: FakeRestoreEnvironment(scans: [scan])).preview(profile: profile)
        #expect(off.possiblyParked.isEmpty)
        #expect(off.unmatched.map(\.snapshotID) == [F.sid(2)])
    }
}

private extension RestoreEngine {
    /// The plan for a given scan (the engine only scans once).
    func planPreview(_ profile: Profile, _ scan: WorkspaceScan) -> RestorePlan {
        RestoreFixtures.plan(profile, scan)
    }
}
