import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Edge cases of the restore planner: empty profiles and scans, missing monitors and Spaces, minimized and
/// full-screen windows, duplicate apps, Stage Manager changes and the step accessors.
@Suite struct RestorePlannerEdgeTests {
    typealias F = RestoreFixtures

    static func kinds(_ plan: RestorePlan) -> [String] { plan.steps.map(\.kind) }

    static let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // MARK: Empty inputs

    @Test func emptyProfileAndEmptyScanGiveAnEmptyPlan() {
        let plan = F.plan(F.profile([]), F.scan([]))
        #expect(plan.isEmpty)
        #expect(plan.warnings.isEmpty)
        #expect(plan.unmatched.isEmpty)
        #expect(plan.missingDesktops.isEmpty)
        #expect(plan.phases.isEmpty)
        #expect(plan.outline.contains("Nothing to do"))
    }

    @Test func emptyProfileHidesEveryRunningAppItDoesNotKnow() {
        let profile = F.profile([], options: ProfileOptions(otherApps: .hide))
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome), F.live(102, F.slack)]))
        #expect(Self.kinds(plan) == ["hideApp", "hideApp"])
        #expect(plan.steps.map(\.app.name) == ["Google Chrome", "Slack"])
    }

    @Test func emptyProfileAsksBeforeQuittingEveryUnknownApp() {
        let profile = F.profile([], options: ProfileOptions(otherApps: .quit))
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome), F.live(102, F.slack)]))
        #expect(Self.kinds(plan) == ["quit", "quit"])
        #expect(plan.steps.allSatisfy { if case .needsConfirmationQuit = $0 { true } else { false } })
    }

    @Test func systemAppsAndWindowsManagerItselfAreNeverHiddenOrQuit() {
        let profile = F.profile([], options: ProfileOptions(otherApps: .hide))
        let scan = F.scan([F.live(101, F.own), F.live(102, F.spotlight), F.live(103, F.chrome)])
        let plan = F.plan(profile, scan)
        #expect(Self.kinds(plan) == ["hideApp"])
        #expect(plan.steps.first?.app == F.chrome)
    }

    @Test func otherAppWithSeveralWindowsIsHiddenOnceAndPidZeroIsSkipped() {
        let profile = F.profile([], options: ProfileOptions(otherApps: .hide))
        let scan = F.scan([
            F.live(101, F.chrome, pid: 555),
            F.live(102, F.chrome, pid: 555),
            F.live(103, F.slack, pid: 0),
        ])
        let plan = F.plan(profile, scan)
        #expect(Self.kinds(plan) == ["hideApp"])
        #expect(plan.steps.first?.app == F.chrome)
    }

    // MARK: Monitors

    @Test func noMonitorAtAllWarnsAndPlacesWindowsAsSaved() {
        let profile = F.profile([F.snap(1, F.chrome)])
        let scan = F.scan([F.live(101, F.chrome, frame: CGRect(x: 300, y: 300, width: 500, height: 400))],
                          displays: [])
        let plan = F.plan(profile, scan)
        #expect(plan.warnings.contains("No monitor was found; frames are used as saved."))
        #expect(Self.kinds(plan) == ["setFrame"])
        guard case .setFrame(_, let frame, _, let beforeFullScreen) = plan.steps[0] else {
            Issue.record("expected a setFrame step")
            return
        }
        #expect(frame == F.defaultFrame)
        #expect(!beforeFullScreen)
    }

    @Test func savedMonitorThatIsGoneFallsBackToTheMainMonitor() {
        // The profile has a window on display B; only display A is connected now.
        let profile = F.profile([F.snap(1, F.chrome, display: F.uuidB)])
        let scan = F.scan([F.live(101, F.chrome)], displays: [F.displayA()], spaces: [F.spacesA()])
        let plan = F.plan(profile, scan)
        #expect(plan.unmatched.isEmpty)
        #expect(!Self.kinds(plan).contains("moveToDesktop"))
        #expect(!Self.kinds(plan).contains("enterFullScreen"))
    }

    @Test func lockedScreenWarningReplacesTheAccessibilityWarning() {
        let profile = F.profile([F.snap(1, F.chrome)])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome)], trusted: false, locked: true))
        #expect(plan.warnings.contains { $0.contains("locked") })
        #expect(!plan.warnings.contains { $0.contains("Accessibility") })
    }

    @Test func unknownSpacesOfAMonitorKeepTheWindowOnItsDesktop() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2))])
        let scan = F.scan([F.live(101, F.chrome)], spaces: [])
        let plan = F.plan(profile, scan)
        #expect(plan.warnings.contains { $0.contains("Spaces of Built-in are unknown") })
        #expect(!Self.kinds(plan).contains("moveToDesktop"))
    }

    @Test func twoWindowsOnAMissingDesktopShareOneMissingDesktopEntry() {
        let profile = F.profile([
            F.snap(1, F.slack, placement: .desktop(number: 3)),
            F.snap(2, F.notes, placement: .desktop(number: 3)),
        ])
        let scan = F.scan([F.live(101, F.slack), F.live(102, F.notes)])
        let plan = F.plan(profile, scan)
        #expect(plan.missingDesktops.count == 1)
        #expect(plan.missingDesktops.first?.snapshotIDs.count == 2)
        #expect(plan.missingDesktops.first?.available == 2)
        #expect(plan.warnings.contains { $0.contains("missing Desktop 3 on Built-in (it has 2)") && $0.contains("2 windows stay") })
    }

    @Test func twoSavedMonitorsOnOneLiveMonitorAreWarnedAbout() {
        let profile = F.profile([])
        let scan = F.scan([], displays: [F.displayA()], spaces: [F.spacesA()])
        let displayMatch = [F.uuidA: F.displayA(), F.uuidB: F.displayA()]
        let plan = RestorePlanner.plan(profile: profile, scan: scan, displayMatch: displayMatch,
                                       match: MatchResult(), options: profile.options)
        #expect(plan.warnings.contains { $0.contains("\"External\" is restored onto \"Built-in\"") })
        #expect(plan.warnings.contains { $0.contains("share one monitor now") })
    }

    // MARK: Minimized and full-screen windows

    @Test func minimizedFullScreenSnapshotIsMinimizedNotEnteredIntoFullScreen() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .fullScreen(position: 0), fullScreen: true, minimized: true)])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome)]))
        #expect(Self.kinds(plan) == ["minimize"])
    }

    @Test func minimizedSnapshotOfAFullScreenWindowLeavesFullScreenThenMinimizes() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .fullScreen(position: 0), fullScreen: true, minimized: true)])
        let live = F.live(101, F.chrome, frame: Self.screen, spaces: [13], fullScreen: true)
        let plan = F.plan(profile, F.scan([live]))
        #expect(Self.kinds(plan) == ["exitFullScreen", "setFrame", "minimize"])
    }

    @Test func minimizedWindowsAreNotRaised() {
        let profile = F.profile([F.snap(1, F.chrome, minimized: true, z: 1)])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome)]))
        #expect(Self.kinds(plan) == ["minimize"])
        #expect(!Self.kinds(plan).contains("raise"))
    }

    @Test func windowThatIsMinimizedInBothPlaceIsLeftAloneWhateverItsFrame() {
        let profile = F.profile([F.snap(1, F.chrome, minimized: true)])
        let live = F.live(101, F.chrome, frame: CGRect(x: 700, y: 50, width: 300, height: 200), minimized: true)
        #expect(F.plan(profile, F.scan([live])).isEmpty)
    }

    // MARK: Launching

    @Test func severalSavedWindowsOfAClosedAppLaunchItOnceWithAllTheirWindows() {
        let profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.chrome, index: 1)])
        let plan = F.plan(profile, F.scan([]))
        #expect(plan.steps == [.launch(app: F.chrome, windowCount: 2)])
        #expect(plan.unmatched.count == 2)
        #expect(plan.unmatched.allSatisfy { $0.reason == "the app is not running; it will be launched" })
    }

    @Test func windowsThatAreNotRestoredDoNotCountTowardTheLaunch() {
        let profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.chrome, index: 1, restore: false)])
        let plan = F.plan(profile, F.scan([]))
        #expect(plan.steps == [.launch(app: F.chrome, windowCount: 1)])
    }

    // MARK: Stage Manager

    @Test func stageManagerChangingSinceCaptureIsAWarning() {
        var profile = F.profile([F.snap(1, F.chrome)])
        profile.stageManagerOn = true
        var scan = F.scan([F.live(101, F.chrome)])
        scan.stageManagerOn = false
        let plan = F.plan(profile, scan)
        #expect(plan.warnings.contains { $0.contains("was on when this profile was captured and is off now") })
    }

    @Test func noStageManagerWarningWhenEitherSideIsUnknown() {
        var profile = F.profile([F.snap(1, F.chrome)])
        var scan = F.scan([F.live(101, F.chrome)])
        scan.stageManagerOn = false
        #expect(!F.plan(profile, scan).warnings.contains { $0.contains("Stage Manager") })

        profile.stageManagerOn = true
        scan.stageManagerOn = nil
        #expect(!F.plan(profile, scan).warnings.contains { $0.contains("Stage Manager") })
    }

    // MARK: Desktops

    @Test func allDesktopsWindowWithTwoDesktopsOnTheMonitorGetsNoWarning() {
        let profile = F.profile([F.snap(1, F.notes, placement: .allDesktops)])
        let plan = F.plan(profile, F.scan([F.live(101, F.notes, spaces: [11, 12])]))
        #expect(!plan.warnings.contains { $0.contains("all Desktops") })
    }

    // MARK: Step accessors

    @Test func appLevelStepsHaveNoTargetButKnowTheirApp() {
        let hide = RestoreStep.hideApp(app: F.chrome, pid: 5)
        let quit = RestoreStep.needsConfirmationQuit(app: F.slack, pid: 6)
        let launch = RestoreStep.launch(app: F.notes, windowCount: 1)
        #expect(hide.target == nil)
        #expect(quit.target == nil)
        #expect(launch.target == nil)
        #expect(hide.app == F.chrome)
        #expect(quit.app == F.slack)
        #expect(launch.app == F.notes)
        #expect(hide.phase == .otherApps)
        #expect(quit.phase == .otherApps)
        #expect(launch.phase == .launch)
        #expect(launch.isLaunch)
        #expect(!hide.isLaunch)
    }

    @Test func removingAPhaseThatIsNotPresentChangesNothing() {
        let plan = F.plan(F.profile([F.snap(1, F.chrome, minimized: true)]), F.scan([F.live(101, F.chrome)]))
        #expect(plan.removing(.launch) == plan)
        #expect(plan.removing(.raise) == plan)
    }
}
