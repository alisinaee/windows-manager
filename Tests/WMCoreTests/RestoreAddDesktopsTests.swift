import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// A Desktop adder that touches nothing: it counts the calls and answers with a Desktop count it keeps itself.
@MainActor
final class FakeDesktopAdder: DesktopAdding {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The Desktops the monitor has now.
    var count: Int
    /// When set, every call throws this message.
    var failure: String?
    /// When true, a call reports the count without growing it.
    var stuck = false
    private(set) var calls = 0

    init(count: Int) {
        self.count = count
    }

    func addDesktop(on display: DisplayIdentity) async throws -> Int {
        calls += 1
        if let failure { throw Failure(message: failure) }
        if !stuck { count += 1 }
        return count
    }
}

@MainActor
@Suite struct RestoreAddDesktopsTests {
    typealias F = RestoreFixtures

    /// Monitor A with `n` Desktops (the first two are ids 11 and 12, the others 30 and up) and its full-screen Spaces.
    static func spacesA(desktops n: Int) -> ScannedSpaces {
        var list: [SpaceInfo] = []
        for index in 0..<n {
            let id: UInt64 = index < 2 ? UInt64(11 + index) : UInt64(30 + index)
            list.append(SpaceInfo(id: id, uuid: "d\(id)", kind: .desktop, index: index, isCurrent: index == 0))
        }
        list.append(SpaceInfo(id: 13, uuid: "s13", kind: .fullscreen, index: n, isCurrent: false))
        list.append(SpaceInfo(id: 14, uuid: "s14", kind: .fullscreen, index: n + 1, isCurrent: false))
        return ScannedSpaces(displayUUID: F.uuidA, currentSpaceID: 11, spaces: list)
    }

    /// Same pipeline as the engine: match monitors, remap, match windows, plan.
    static func plan(_ profile: Profile, _ scan: WorkspaceScan, adding: Bool) -> RestorePlan {
        let displayMatch = DisplayMap.match(saved: profile.displays, current: scan.displays)
        let snapshots = RestorePlanner.remap(profile.windows, savedDisplays: profile.displays, displayMatch: displayMatch)
        let match = WindowMatcher.match(snapshots: snapshots, live: scan.windows)
        return RestorePlanner.plan(profile: profile, scan: scan, displayMatch: displayMatch, match: match,
                                   options: profile.options, addMissingDesktops: adding)
    }

    /// Two windows: Chrome wants Desktop 3 of monitor A (which has 2), Slack wants Desktop 2 (exists).
    static func chromeOnThreeSlackOnTwo() -> Profile {
        F.profile([F.snap(1, F.chrome, placement: .desktop(number: 3)), F.snap(2, F.slack, placement: .desktop(number: 2))])
    }

    static func liveChromeAndSlack(desktopsOnA: Int) -> WorkspaceScan {
        F.scan([F.live(101, F.chrome, spaces: [11]), F.live(102, F.slack, spaces: [11])],
               spaces: [spacesA(desktops: desktopsOnA), F.spacesB()])
    }

    static func engine(_ env: FakeRestoreEnvironment, adder: FakeDesktopAdder, adding: Bool = true) -> RestoreEngine {
        var configuration = RestoreEngine.Configuration()
        configuration.addMissingDesktops = adding
        return RestoreEngine(environment: env, configuration: configuration, desktopAdder: adder)
    }

    // MARK: Planning

    @Test func optionOffKeepsTheWarningAndNoAddStep() {
        let plan = Self.plan(Self.chromeOnThreeSlackOnTwo(), Self.liveChromeAndSlack(desktopsOnA: 2), adding: false)
        #expect(!plan.steps.contains { $0.kind == "addDesktop" })
        #expect(plan.warnings.contains { $0.contains("missing Desktop 3 on Built-in (it has 2)") })
        #expect(plan.missingDesktops.map(\.number) == [3])
    }

    @Test func optionOnEmitsOneAddStepBeforeTheMoves() {
        let plan = Self.plan(Self.chromeOnThreeSlackOnTwo(), Self.liveChromeAndSlack(desktopsOnA: 2), adding: true)
        #expect(plan.steps.count == 2)
        #expect(plan.steps[0] == .addDesktop(display: F.displayA(), count: 1))
        #expect(plan.steps[0].phase == .addDesktop)
        #expect(plan.steps[0].description == "add 1 Desktop to Built-in")
        guard case .moveToDesktop(let target, let desktop, _, _, _, _) = plan.steps[1] else {
            Issue.record("expected the move of Slack after the add")
            return
        }
        #expect(target.app == F.slack)
        #expect(desktop == 2)
        #expect(!plan.warnings.contains { $0.contains("missing Desktop") })
        #expect(plan.phases.firstIndex(of: .addDesktop)! < plan.phases.firstIndex(of: .moveToDesktop)!)
    }

    @Test func optionOnWithEnoughDesktopsAddsNothing() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2))])
        let plan = Self.plan(profile, Self.liveChromeAndSlack(desktopsOnA: 2), adding: true)
        #expect(!plan.steps.contains { $0.kind == "addDesktop" })
    }

    @Test func addCountIsCappedAtEightPerRun() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 12))])
        let plan = Self.plan(profile, Self.liveChromeAndSlack(desktopsOnA: 2), adding: true)
        #expect(plan.steps.first == .addDesktop(display: F.displayA(), count: RestorePlanner.maxAddedDesktopsPerRun))
        #expect(RestorePlanner.maxAddedDesktopsPerRun == 8)
        #expect(plan.warnings.contains { $0.contains("missing Desktop 12") && $0.contains("limit of 8") })
    }

    // MARK: Engine

    @Test func engineAddsThenPlansTheMoveOntoTheNewDesktop() async {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 3))])
        let env = FakeRestoreEnvironment(scans: [
            F.scan([F.live(101, F.chrome, spaces: [11])], spaces: [Self.spacesA(desktops: 2), F.spacesB()]),
            F.scan([F.live(101, F.chrome, spaces: [11])], spaces: [Self.spacesA(desktops: 3), F.spacesB()]),
        ])
        let adder = FakeDesktopAdder(count: 2)
        let report = await Self.engine(env, adder: adder).run(profile)

        #expect(adder.calls == 1)
        #expect(env.actions == ["moveToDesktop:101->32"])
        #expect(report.steps.map(\.kind) == ["addDesktop", "moveToDesktop"])
        #expect(report.steps[0].status.isDone)
        #expect(report.steps[0].phase == .addDesktop)
        #expect(report.steps[0].note == "added 1; Built-in has 3 Desktops now")
        #expect(report.isClean)
    }

    @Test func optionOffNeverCallsTheAdder() async {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 3))])
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome, spaces: [11])], spaces: [Self.spacesA(desktops: 2), F.spacesB()])])
        let adder = FakeDesktopAdder(count: 2)
        let report = await Self.engine(env, adder: adder, adding: false).run(profile)

        #expect(adder.calls == 0)
        #expect(env.actions.isEmpty)
        #expect(!report.steps.contains { $0.kind == "addDesktop" })
        #expect(report.warnings.contains { $0.contains("missing Desktop 3") })
    }

    @Test func failingAdderFailsOnlyThatStep() async {
        let profile = Self.chromeOnThreeSlackOnTwo()
        let env = FakeRestoreEnvironment(scans: [Self.liveChromeAndSlack(desktopsOnA: 2)])
        let adder = FakeDesktopAdder(count: 2)
        adder.failure = "Mission Control did not open"
        let report = await Self.engine(env, adder: adder).run(profile)

        #expect(adder.calls == 1)
        #expect(report.steps.map(\.kind) == ["addDesktop", "moveToDesktop"])
        #expect(report.steps[0].status == .failed("could not add a Desktop to Built-in: Mission Control did not open"))
        #expect(report.steps[1].status.isDone)
        #expect(env.actions == ["moveToDesktop:102->12"])
        // The Desktop that could not be added is still reported after the second plan.
        #expect(report.warnings.contains { $0.contains("missing Desktop 3") })
        #expect(report.totals.failed == 1)
    }

    /// Mission Control animates the windows; the rescan after an add must wait for that, or it plans moves for
    /// windows that are already in place (S7 re-run).
    @Test func rescanWaitsAfterTheAddStep() async {
        let env = FakeRestoreEnvironment(scans: [Self.liveChromeAndSlack(desktopsOnA: 2)])
        let adder = FakeDesktopAdder(count: 2)
        adder.failure = "Mission Control did not open"
        _ = await Self.engine(env, adder: adder).run(Self.chromeOnThreeSlackOnTwo())

        let scans = env.calls.enumerated().filter { $0.element == "scan" }.map(\.offset)
        #expect(scans.count >= 2)
        let between = env.calls[scans[0]..<scans[1]]
        #expect(between.contains { $0.hasPrefix("sleep:") })
    }

    @Test func raiseOfAWindowInAnotherStageEndsSkippedNotFailed() async {
        let profile = F.profile([F.snap(1, F.chrome, z: 1), F.snap(2, F.slack, z: 0)])
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome), F.live(102, F.slack)])])
        // Live order chrome, slack but saved slack in front: both are raised.
        env.skips["raise:102"] = "the window cannot be raised"
        let report = await RestoreEngine(environment: env).run(profile)
        let raises = report.steps.filter { $0.kind == "raise" }
        #expect(!raises.isEmpty)
        #expect(raises.allSatisfy { $0.status.isDone || $0.status.isSkipped })
        #expect(raises.contains { $0.status.isSkipped })
        #expect(report.totals.failed == 0)
    }

    @Test func addThatDoesNotGrowTheCountFails() async {
        let profile = Self.chromeOnThreeSlackOnTwo()
        let env = FakeRestoreEnvironment(scans: [Self.liveChromeAndSlack(desktopsOnA: 2)])
        let adder = FakeDesktopAdder(count: 2)
        adder.stuck = true
        let report = await Self.engine(env, adder: adder).run(profile)

        #expect(report.steps[0].status == .failed("Built-in still has 2 Desktops after the add (it had 2)"))
        #expect(env.actions == ["moveToDesktop:102->12"])
    }

    @Test func engineStopsAddingAtTheCap() async {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 12))])
        let env = FakeRestoreEnvironment(scans: [
            F.scan([F.live(101, F.chrome, spaces: [11])], spaces: [Self.spacesA(desktops: 2), F.spacesB()]),
            F.scan([F.live(101, F.chrome, spaces: [11])], spaces: [Self.spacesA(desktops: 10), F.spacesB()]),
        ])
        let adder = FakeDesktopAdder(count: 2)
        let report = await Self.engine(env, adder: adder).run(profile)

        #expect(adder.calls == RestorePlanner.maxAddedDesktopsPerRun)
        #expect(adder.count == 10)
        #expect(report.steps[0].status.isDone)
        #expect(report.steps[0].note == "added 8; Built-in has 10 Desktops now")
        // Desktop 12 still does not exist: the window stays where it is.
        #expect(env.actions.isEmpty)
        #expect(report.warnings.contains { $0.contains("missing Desktop 12") })
    }
}
