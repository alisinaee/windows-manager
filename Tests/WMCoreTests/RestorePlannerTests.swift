import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Fixtures shared by the planner and engine tests: two monitors, their Spaces, saved and live windows.
enum RestoreFixtures {
    static let chrome = AppRef(bundleID: "com.google.Chrome", name: "Google Chrome")
    static let slack = AppRef(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    static let notes = AppRef(bundleID: "com.apple.Notes", name: "Notes")
    static let safari = AppRef(bundleID: "com.apple.Safari", name: "Safari")
    static let finder = AppRef(bundleID: "com.apple.finder", name: "Finder")
    static let mail = AppRef(bundleID: "com.apple.mail", name: "Mail")
    static let own = AppRef(bundleID: WorkspaceScanner.ownBundleID, name: "Windows Manager")
    static let spotlight = AppRef(bundleID: "com.apple.Spotlight", name: "Spotlight")

    static let uuidA = "AAAAAAAA-0000-4000-8000-000000000001"
    static let uuidB = "BBBBBBBB-0000-4000-8000-000000000002"

    /// Main display, 1920x1080 at 0,0.
    static func displayA(uuid: String = uuidA) -> DisplayIdentity {
        DisplayIdentity(uuid: uuid, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                        visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055), isMain: true, isBuiltIn: true)
    }

    /// Second display, 2560x1440 at 1920,0.
    static func displayB(uuid: String = uuidB) -> DisplayIdentity {
        DisplayIdentity(uuid: uuid, name: "External", frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
                        visibleFrame: CGRect(x: 1920, y: 0, width: 2560, height: 1440), isMain: false, isBuiltIn: false)
    }

    /// Display A: Desktop 1 (id 11), Desktop 2 (id 12), two full-screen Spaces (ids 13, 14).
    static func spacesA(current: UInt64 = 11) -> ScannedSpaces {
        ScannedSpaces(displayUUID: uuidA, currentSpaceID: current, spaces: [
            SpaceInfo(id: 11, uuid: "s11", kind: .desktop, index: 0, isCurrent: current == 11),
            SpaceInfo(id: 12, uuid: "s12", kind: .desktop, index: 1, isCurrent: current == 12),
            SpaceInfo(id: 13, uuid: "s13", kind: .fullscreen, index: 2, isCurrent: current == 13),
            SpaceInfo(id: 14, uuid: "s14", kind: .fullscreen, index: 3, isCurrent: current == 14),
        ])
    }

    /// Display B: Desktop 1 (id 21), one full-screen Space (id 22).
    static func spacesB(current: UInt64 = 21) -> ScannedSpaces {
        ScannedSpaces(displayUUID: uuidB, currentSpaceID: current, spaces: [
            SpaceInfo(id: 21, uuid: "s21", kind: .desktop, index: 0, isCurrent: current == 21),
            SpaceInfo(id: 22, uuid: "s22", kind: .fullscreen, index: 1, isCurrent: current == 22),
        ])
    }

    static func sid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static let defaultFrame = CGRect(x: 100, y: 100, width: 800, height: 600)

    static func snap(_ n: Int, _ app: AppRef, title: String? = nil, display: String = uuidA,
                     frame: CGRect = defaultFrame, placement: SpacePlacement = .desktop(number: 1),
                     fullScreen: Bool = false, minimized: Bool = false, z: Int = 0, index: Int = 0,
                     restore: Bool = true) -> WindowSnapshot {
        WindowSnapshot(id: sid(n), app: app, title: title, titleMatch: .any, indexInApp: index, displayUUID: display,
                       frame: frame, relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), placement: placement,
                       isFullScreen: fullScreen, isMinimized: minimized, zIndex: z, restore: restore)
    }

    static func live(_ id: UInt32, _ app: AppRef, title: String? = nil, display: String? = uuidA,
                     frame: CGRect = defaultFrame, spaces: [UInt64] = [11], fullScreen: Bool = false,
                     minimized: Bool = false, index: Int = 0, current: Bool = true, pid: Int32? = nil) -> LiveWindow {
        LiveWindow(windowID: id, pid: pid ?? Int32(1000 + id), app: app, title: title, frame: frame, displayUUID: display,
                   spaceIDs: spaces, isFullScreen: fullScreen, isMinimized: minimized, indexInApp: index,
                   isOnCurrentSpace: current)
    }

    static func scan(_ windows: [LiveWindow], displays: [DisplayIdentity]? = nil, spaces: [ScannedSpaces]? = nil,
                     trusted: Bool = true, locked: Bool = false) -> WorkspaceScan {
        let shown = displays ?? [displayA(), displayB()]
        let lists = spaces ?? (displays == nil ? [spacesA(), spacesB()] : [])
        return WorkspaceScan(displays: shown, spaces: lists, windows: windows, accessibilityTrusted: trusted,
                             screenIsLocked: locked)
    }

    static func profile(_ windows: [WindowSnapshot], displays: [DisplayIdentity]? = nil,
                        options: ProfileOptions = ProfileOptions(), spaces: [SpaceSnapshot] = []) -> Profile {
        Profile(name: "Work", monitorSetKey: "key", displays: displays ?? [displayA(), displayB()], spaces: spaces,
                windows: windows, options: options)
    }

    /// The same pipeline the engine runs: match monitors, remap, match windows, plan.
    static func plan(_ profile: Profile, _ scan: WorkspaceScan, options: ProfileOptions? = nil) -> RestorePlan {
        let displayMatch = DisplayMap.match(saved: profile.displays, current: scan.displays)
        let snapshots = RestorePlanner.remap(profile.windows, savedDisplays: profile.displays, displayMatch: displayMatch)
        let match = WindowMatcher.match(snapshots: snapshots, live: scan.windows)
        return RestorePlanner.plan(profile: profile, scan: scan, displayMatch: displayMatch, match: match,
                                   options: options ?? profile.options)
    }
}

@Suite struct RestorePlannerTests {
    typealias F = RestoreFixtures

    static func kinds(_ plan: RestorePlan) -> [String] { plan.steps.map(\.kind) }

    // MARK: Nothing to do

    @Test func windowsInPlaceNeedNoSteps() {
        let profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.slack, frame: CGRect(x: 300, y: 300, width: 500, height: 400))])
        let scan = F.scan([F.live(101, F.chrome), F.live(102, F.slack, frame: CGRect(x: 300, y: 300, width: 500, height: 400))])
        let plan = F.plan(profile, scan)
        #expect(plan.isEmpty)
        #expect(plan.unmatched.isEmpty)
        #expect(plan.outline.contains("Nothing to do"))
    }

    // MARK: Phases

    @Test func exitFullScreenThenFrame() {
        // The live window is full screen and its frame is screen-sized; the snapshot is a normal window on Desktop 1.
        let profile = F.profile([F.snap(1, F.chrome)])
        let live = F.live(101, F.chrome, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), spaces: [13], fullScreen: true)
        let plan = F.plan(profile, F.scan([live]))
        // After leaving full screen the window lands on a Desktop that the scan cannot know, so it is also sent to Desktop 1.
        #expect(Self.kinds(plan) == ["exitFullScreen", "moveToDesktop", "setFrame"])
        guard case .setFrame(_, let frame, let from, _) = plan.steps[2] else {
            Issue.record("expected a setFrame step")
            return
        }
        #expect(frame == F.defaultFrame)
        #expect(from.width == 1920)
    }

    @Test func fullScreenWindowThatShouldStayFullScreenIsLeftAlone() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let profile = F.profile([F.snap(1, F.chrome, frame: screen, placement: .fullScreen(position: 2), fullScreen: true)])
        let live = F.live(101, F.chrome, frame: screen, spaces: [13], fullScreen: true)
        #expect(F.plan(profile, F.scan([live])).isEmpty)
    }

    @Test func unminimizePlanned() {
        let profile = F.profile([F.snap(1, F.chrome)])
        let live = F.live(101, F.chrome, spaces: [], minimized: true)
        let plan = F.plan(profile, F.scan([live]))
        #expect(plan.steps.first?.kind == "unminimize")
        // The window has no Space while minimized, so it is also sent to Desktop 1.
        #expect(Self.kinds(plan).contains("moveToDesktop"))
    }

    @Test func moveToDesktopWhenDesktopDiffers() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2))])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome, spaces: [11])]))
        #expect(plan.steps.count == 1)
        guard case .moveToDesktop(let target, let desktop, let spaceID, let display, let from, let fromDisplay) = plan.steps[0] else {
            Issue.record("expected a moveToDesktop step")
            return
        }
        #expect(target.windowID == 101)
        #expect(desktop == 2)
        #expect(spaceID == 12)
        #expect(display == "Built-in")
        #expect(from == 1)
        #expect(fromDisplay == nil)
        #expect(plan.steps[0].description == "move to Desktop 2 on Built-in (now on Desktop 1): Google Chrome (window 101)")
    }

    @Test func noMoveWhenAlreadyOnTheDesktop() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2))])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome, spaces: [12], current: false)]))
        #expect(plan.isEmpty)
    }

    @Test func moveToDesktopOnTheOtherMonitor() {
        // The window is on Desktop 1 of A, the snapshot wants Desktop 1 of B.
        let profile = F.profile([F.snap(1, F.chrome, display: F.uuidB, frame: CGRect(x: 2000, y: 100, width: 800, height: 600))])
        let live = F.live(101, F.chrome, frame: CGRect(x: 2000, y: 100, width: 800, height: 600), spaces: [11])
        let plan = F.plan(profile, F.scan([live]))
        guard case .moveToDesktop(_, let desktop, let spaceID, let display, _, let fromDisplay) = plan.steps.first else {
            Issue.record("expected a moveToDesktop step first")
            return
        }
        #expect(desktop == 1)
        #expect(spaceID == 21)
        #expect(display == "External")
        #expect(fromDisplay == "Built-in")
        #expect(plan.steps[0].description.contains("(now on Desktop 1 of Built-in)"))
    }

    @Test func missingDesktopIsRecordedAndSkipped() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 3))])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome, spaces: [11])]))
        #expect(!Self.kinds(plan).contains("moveToDesktop"))
        #expect(plan.missingDesktops.count == 1)
        #expect(plan.missingDesktops.first?.number == 3)
        #expect(plan.missingDesktops.first?.available == 2)
        #expect(plan.missingDesktops.first?.snapshotIDs == [F.sid(1)])
        #expect(plan.warnings.contains { $0.contains("missing Desktop 3") })
    }

    @Test func setFrameSkippedWithinTwoPointsAndPlannedBeyond() {
        let close = F.defaultFrame.offsetBy(dx: 1.5, dy: -1.5)
        let far = F.defaultFrame.offsetBy(dx: 3, dy: 0)
        let profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.slack)])

        let near = F.plan(profile, F.scan([F.live(101, F.chrome, frame: close), F.live(102, F.slack, frame: far)]))
        #expect(near.steps.count == 1)
        guard case .setFrame(let target, let frame, let from, let before) = near.steps[0] else {
            Issue.record("expected a setFrame step")
            return
        }
        #expect(target.windowID == 102)
        #expect(frame == F.defaultFrame)
        #expect(from == far)
        #expect(!before)
    }

    @Test func enterFullScreenWhenSnapshotIsFullScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let profile = F.profile([F.snap(1, F.chrome, frame: screen, placement: .fullScreen(position: 2), fullScreen: true)])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome, frame: F.defaultFrame)]))
        // The window is already on monitor A, so no move first; no frame step for full-screen snapshots.
        #expect(Self.kinds(plan) == ["enterFullScreen"])
        guard case .enterFullScreen(_, let uuid, let display, let position) = plan.steps[0] else {
            Issue.record("expected an enterFullScreen step")
            return
        }
        #expect(uuid == F.uuidA)
        #expect(display == "Built-in")
        #expect(position == 2)
    }

    @Test func fullScreenWindowFirstMovesToItsMonitor() {
        let screenB = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let profile = F.profile([F.snap(1, F.chrome, display: F.uuidB, frame: screenB, placement: .fullScreen(position: 1), fullScreen: true)])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome, frame: F.defaultFrame)]))
        #expect(Self.kinds(plan) == ["setFrame", "enterFullScreen"])
        guard case .setFrame(_, let frame, _, let before) = plan.steps[0] else {
            Issue.record("expected a setFrame step")
            return
        }
        #expect(before)
        #expect(screenB.contains(frame))
    }

    @Test func fullScreenEnteredPerMonitorInSavedSpaceOrder() {
        let screenA = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screenB = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let profile = F.profile([
            F.snap(1, F.slack, display: F.uuidB, frame: screenB, placement: .fullScreen(position: 1), fullScreen: true),
            F.snap(2, F.chrome, display: F.uuidA, frame: screenA, placement: .fullScreen(position: 3), fullScreen: true),
            F.snap(3, F.notes, display: F.uuidA, frame: screenA, placement: .fullScreen(position: 2), fullScreen: true),
        ])
        let scan = F.scan([
            F.live(101, F.slack, frame: CGRect(x: 2000, y: 100, width: 800, height: 600)),
            F.live(102, F.chrome),
            F.live(103, F.notes),
        ].map { var w = $0; if w.windowID == 101 { w.displayUUID = F.uuidB; w.spaceIDs = [21] }; return w })
        let plan = F.plan(profile, scan)
        let entered = plan.steps(in: .enterFullScreen).compactMap { $0.target?.app.name }
        // Monitor A first (main display), its Spaces in saved order, then monitor B.
        #expect(entered == ["Notes", "Google Chrome", "Slack"])
    }

    @Test func minimizePlannedAfterTheFrame() {
        let profile = F.profile([F.snap(1, F.chrome, minimized: true)])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome, frame: F.defaultFrame.offsetBy(dx: 50, dy: 0))]))
        #expect(Self.kinds(plan) == ["setFrame", "minimize"])
    }

    @Test func minimizedWindowThatShouldStayMinimizedIsLeftAlone() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .unknown, minimized: true)])
        let live = F.live(101, F.chrome, frame: F.defaultFrame.offsetBy(dx: 50, dy: 0), spaces: [], minimized: true)
        #expect(F.plan(profile, F.scan([live])).isEmpty)
    }

    // MARK: Raise

    @Test func raiseBackToFrontByZIndex() {
        // Saved front to back: Slack (z 0), Chrome (z 1), Notes (z 2). Live order is scrambled.
        let profile = F.profile([F.snap(1, F.chrome, z: 1), F.snap(2, F.slack, z: 0), F.snap(3, F.notes, z: 2)])
        let scan = F.scan([F.live(103, F.notes), F.live(101, F.chrome), F.live(102, F.slack)])
        let plan = F.plan(profile, scan)
        #expect(plan.steps.allSatisfy { $0.kind == "raise" })
        #expect(plan.steps.compactMap { $0.target?.app.name } == ["Notes", "Google Chrome", "Slack"])
        guard case .raise(_, let first) = plan.steps[0], case .raise(_, let last) = plan.steps[2] else {
            Issue.record("expected raise steps")
            return
        }
        #expect(first == 2)
        #expect(last == 0)
    }

    @Test func noRaiseWhenAlreadyInSavedOrder() {
        let profile = F.profile([F.snap(1, F.chrome, z: 0), F.snap(2, F.slack, z: 1)])
        let scan = F.scan([F.live(101, F.chrome), F.live(102, F.slack)])
        #expect(F.plan(profile, scan).isEmpty)
    }

    @Test func raiseSkipsWindowsOnOtherSpaces() {
        // Slack and Notes are on Desktop 1 of A (visible); Chrome is on Desktop 2 (not visible) and stays there.
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2), z: 1), F.snap(2, F.slack, z: 0),
                                 F.snap(3, F.notes, z: 2)])
        let scan = F.scan([F.live(103, F.notes), F.live(101, F.chrome, spaces: [12], current: false), F.live(102, F.slack)])
        let plan = F.plan(profile, scan)
        #expect(plan.steps.allSatisfy { $0.kind == "raise" })
        #expect(plan.steps.compactMap { $0.target?.app.name } == ["Notes", "Slack"])
    }

    @Test func raiseAfterMoveOnlyWhenTheDesktopIsVisible() {
        // Chrome moves to Desktop 2, which is the current Space of display A: visible, so it is raised.
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2), z: 0),
                                 F.snap(2, F.slack, placement: .desktop(number: 2), z: 1)])
        let scan = F.scan([F.live(102, F.slack, spaces: [12]), F.live(101, F.chrome, spaces: [11], current: false)],
                          spaces: [F.spacesA(current: 12), F.spacesB()])
        let plan = F.plan(profile, scan)
        #expect(Self.kinds(plan).contains("moveToDesktop"))
        #expect(plan.steps(in: .raise).compactMap { $0.target?.app.name } == ["Slack", "Google Chrome"])
    }

    // MARK: Order and options

    @Test func phasesAreGroupedInOrder() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let profile = F.profile([
            F.snap(1, F.chrome, placement: .desktop(number: 2), z: 3),
            F.snap(2, F.slack, minimized: true, z: 4),
            F.snap(3, F.notes, frame: screen, placement: .fullScreen(position: 2), fullScreen: true, z: 1),
            F.snap(4, F.safari, z: 0),
            F.snap(5, F.mail, z: 2),
        ], options: ProfileOptions(otherApps: .hide))
        let scan = F.scan([
            F.live(101, F.chrome, spaces: [11]),
            F.live(102, F.slack),
            F.live(103, F.notes),
            F.live(104, F.safari, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), spaces: [13], fullScreen: true),
            F.live(105, F.mail, spaces: [], minimized: true),
            F.live(106, F.finder),
        ])
        let plan = F.plan(profile, scan)
        let phases = plan.steps.map(\.phase)
        #expect(phases == phases.sorted())
        #expect(Set(phases).isSuperset(of: [.exitFullScreen, .unminimize, .moveToDesktop, .setFrame, .enterFullScreen,
                                            .minimize, .otherApps]))
        #expect(plan.phases == RestorePhase.allCases.filter { phases.contains($0) })
    }

    @Test func windowsWithRestoreOffAreIgnored() {
        let profile = F.profile([F.snap(1, F.chrome, restore: false), F.snap(2, F.slack)])
        let scan = F.scan([F.live(101, F.chrome, frame: F.defaultFrame.offsetBy(dx: 500, dy: 0)),
                           F.live(102, F.slack, frame: F.defaultFrame.offsetBy(dx: 500, dy: 0))])
        let plan = F.plan(profile, scan)
        #expect(plan.steps.compactMap { $0.target?.windowID } == [102])
        #expect(plan.unmatched.isEmpty)
    }

    @Test func restoreSpacesOffSkipsDesktopMoves() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2))],
                                options: ProfileOptions(restoreSpaces: false))
        #expect(F.plan(profile, F.scan([F.live(101, F.chrome, spaces: [11])])).isEmpty)
    }

    @Test func restoreFullScreenOffSkipsEntering() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let profile = F.profile([F.snap(1, F.chrome, frame: screen, placement: .fullScreen(position: 2), fullScreen: true)],
                                options: ProfileOptions(restoreFullScreen: false))
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome)]))
        #expect(plan.isEmpty)
        #expect(plan.warnings.contains { $0.contains("restoring full screen is switched off") })
    }

    @Test func restoreFullScreenOffStillLeavesFullScreenForNormalWindows() {
        let profile = F.profile([F.snap(1, F.chrome)], options: ProfileOptions(restoreFullScreen: false))
        let live = F.live(101, F.chrome, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), spaces: [13], fullScreen: true)
        #expect(Self.kinds(F.plan(profile, F.scan([live]))).prefix(1) == ["exitFullScreen"])
    }

    @Test func explicitOptionsOverrideTheProfile() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2))])
        let scan = F.scan([F.live(101, F.chrome, spaces: [11])])
        #expect(!F.plan(profile, scan).isEmpty)
        #expect(F.plan(profile, scan, options: ProfileOptions(restoreSpaces: false)).isEmpty)
    }

    // MARK: Launch and unmatched

    @Test func appsThatAreNotRunningAreLaunched() {
        let profile = F.profile([F.snap(1, F.slack), F.snap(2, F.slack, index: 1), F.snap(3, F.chrome)])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome)]))
        #expect(plan.steps(in: .launch) == [.launch(app: F.slack, windowCount: 2)])
        #expect(plan.steps.first?.isLaunch == true)
        #expect(plan.unmatched.map(\.snapshotID) == [F.sid(1), F.sid(2)])
        #expect(plan.unmatched.allSatisfy { $0.reason.contains("will be launched") })
    }

    @Test func launchingCanBeSwitchedOff() {
        let profile = F.profile([F.snap(1, F.slack)], options: ProfileOptions(launchMissingApps: false))
        let plan = F.plan(profile, F.scan([]))
        #expect(plan.steps(in: .launch).isEmpty)
        #expect(plan.unmatched.count == 1)
        #expect(plan.unmatched[0].reason.contains("switched off"))
    }

    @Test func runningAppWithFewerWindowsIsNotLaunchedAgain() {
        let profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.chrome, index: 1)])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome)]))
        #expect(plan.steps(in: .launch).isEmpty)
        #expect(plan.unmatched.count == 1)
        #expect(plan.unmatched[0].reason.contains("fewer windows"))
    }

    // MARK: Other apps

    private static func otherAppsScan() -> WorkspaceScan {
        F.scan([
            F.live(101, F.chrome),
            F.live(102, F.safari, pid: 2001), F.live(103, F.safari, pid: 2001), // one app, two windows
            F.live(104, F.finder, pid: 2002),
            F.live(105, F.own, pid: 2003),
            F.live(106, F.spotlight, pid: 2004),
            F.live(107, AppRef(bundleID: "com.apple.dock", name: "Dock"), pid: 2005),
        ])
    }

    @Test func otherAppsLeaveDoesNothing() {
        let profile = F.profile([F.snap(1, F.chrome)], options: ProfileOptions(otherApps: .leave))
        #expect(F.plan(profile, Self.otherAppsScan()).steps(in: .otherApps).isEmpty)
    }

    @Test func otherAppsHideSkipsProfileAppsAndSystemApps() {
        let profile = F.profile([F.snap(1, F.chrome)], options: ProfileOptions(otherApps: .hide))
        let steps = F.plan(profile, Self.otherAppsScan()).steps(in: .otherApps)
        #expect(steps == [.hideApp(app: F.safari, pid: 2001), .hideApp(app: F.finder, pid: 2002)])
    }

    @Test func otherAppsQuitNeedsConfirmation() {
        let profile = F.profile([F.snap(1, F.chrome)], options: ProfileOptions(otherApps: .quit))
        let steps = F.plan(profile, Self.otherAppsScan()).steps(in: .otherApps)
        #expect(steps == [.needsConfirmationQuit(app: F.safari, pid: 2001), .needsConfirmationQuit(app: F.finder, pid: 2002)])
        #expect(steps.allSatisfy { $0.phase == .otherApps })
    }

    @Test func finderInTheProfileIsNotHidden() {
        let profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.finder)], options: ProfileOptions(otherApps: .hide))
        let steps = F.plan(profile, Self.otherAppsScan()).steps(in: .otherApps)
        #expect(steps == [.hideApp(app: F.safari, pid: 2001)])
    }

    // MARK: Monitors

    @Test func framesAreRemappedWhenTheMonitorChanged() {
        // Saved: one 2560x1440 monitor with a window at its right edge. Now: only a 1920x1080 monitor.
        let savedDisplay = DisplayIdentity(uuid: "OLD-MONITOR", name: "Old", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                           visibleFrame: CGRect(x: 0, y: 25, width: 2560, height: 1415), isMain: true, isBuiltIn: false)
        let saved = F.snap(1, F.chrome, display: "OLD-MONITOR", frame: CGRect(x: 1800, y: 100, width: 800, height: 600))
        let profile = F.profile([saved], displays: [savedDisplay])
        let live = F.live(101, F.chrome, frame: CGRect(x: 50, y: 50, width: 400, height: 300))
        let scan = F.scan([live], displays: [F.displayA()], spaces: [F.spacesA()])
        let plan = F.plan(profile, scan)

        guard case .setFrame(_, let frame, _, _) = plan.steps.first else {
            Issue.record("expected a setFrame step")
            return
        }
        #expect(F.displayA().visibleFrame.contains(frame))
        #expect(frame.width == 800)
        #expect(frame.maxX == 1920)   // the window still touches the right edge
        #expect(plan.warnings.contains { $0.contains("\"Old\"") && $0.contains("\"Built-in\"") })
        #expect(plan.unmatched.isEmpty)
    }

    @Test func remapChangesDisplayAndFrameOnly() {
        let savedDisplay = DisplayIdentity(uuid: "old", name: "Old", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                           visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440), isMain: true, isBuiltIn: false)
        let saved = F.snap(1, F.chrome, title: "Inbox", display: "OLD", frame: CGRect(x: 2000, y: 0, width: 560, height: 400))
        let live = F.displayA()
        let mapped = RestorePlanner.remap([saved], savedDisplays: [savedDisplay], displayMatch: ["old": live])[0]
        #expect(mapped.displayUUID == live.uuid)
        #expect(mapped.id == saved.id)
        #expect(mapped.title == "Inbox")
        #expect(live.visibleFrame.contains(mapped.frame))
        #expect(mapped.relativeFrame == saved.relativeFrame)
    }

    @Test func remapLeavesUnmatchedDisplaysAlone() {
        let saved = F.snap(1, F.chrome, display: "UNKNOWN")
        let mapped = RestorePlanner.remap([saved], savedDisplays: [F.displayA()], displayMatch: [:])
        #expect(mapped == [saved])
    }

    // MARK: Warnings and robustness

    @Test func warnsWhenAccessibilityIsNotGranted() {
        let profile = F.profile([F.snap(1, F.chrome)])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome)], trusted: false))
        #expect(plan.warnings.contains { $0.contains("Accessibility") })
        let locked = F.plan(profile, F.scan([F.live(101, F.chrome)], locked: true))
        #expect(locked.warnings.contains { $0.contains("locked") })
    }

    @Test func ambiguousMatchesAreReported() {
        let profile = F.profile([F.snap(1, F.chrome)])
        let scan = F.scan([F.live(101, F.chrome, title: "Inbox")])
        let match = MatchResult(matched: [Match(snapshotID: F.sid(1), windowID: 101, score: MatchScore(total: 10, reasons: []))],
                                ambiguous: [F.sid(1)])
        let plan = RestorePlanner.plan(profile: profile, scan: scan, displayMatch: [:], match: match, options: profile.options)
        #expect(plan.ambiguous == [F.sid(1)])
        #expect(plan.warnings.contains { $0.contains("ambiguous") })
    }

    @Test func staleMatchesAreSkipped() {
        let profile = F.profile([F.snap(1, F.chrome)])
        let match = MatchResult(matched: [Match(snapshotID: F.sid(1), windowID: 999, score: MatchScore(total: 1, reasons: []))])
        let plan = RestorePlanner.plan(profile: profile, scan: F.scan([]), displayMatch: [:], match: match, options: profile.options)
        #expect(plan.steps.isEmpty)
        #expect(plan.warnings.contains { $0.contains("no longer there") })
    }

    @Test func allDesktopsWindowsGetAWarning() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .allDesktops)])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome)]))
        #expect(!Self.kinds(plan).contains("moveToDesktop"))
        #expect(plan.warnings.contains { $0.contains("all Desktops") })
    }

    @Test func splitViewWindowsGetAWarning() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let profile = F.profile([
            F.snap(1, F.chrome, frame: screen, placement: .fullScreen(position: 2), fullScreen: true),
            F.snap(2, F.notes, frame: screen, placement: .fullScreen(position: 2), fullScreen: true),
        ], spaces: [SpaceSnapshot(displayUUID: F.uuidA, position: 2, kind: .fullScreen,
                                  fullScreenWindowIDs: [F.sid(1), F.sid(2)])])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome), F.live(102, F.notes)]))
        #expect(plan.warnings.filter { $0.contains("Split View") }.count == 2)
    }

    // MARK: Text

    @Test func everyStepDescribesItself() {
        let target = RestoreTarget(snapshotID: F.sid(1), windowID: 84, pid: 10, app: F.chrome, title: "Inbox")
        let steps: [RestoreStep] = [
            .launch(app: F.slack, windowCount: 2),
            .exitFullScreen(target), .unminimize(target),
            .moveToDesktop(target, desktop: 2, spaceID: 12, displayName: "Built-in", from: 1, fromDisplayName: nil),
            .setFrame(target, frame: F.defaultFrame, from: .zero, beforeFullScreen: false),
            .enterFullScreen(target, displayUUID: F.uuidA, displayName: "Built-in", spacePosition: 2),
            .minimize(target), .raise(target, zIndex: 1),
            .hideApp(app: F.safari, pid: 5), .needsConfirmationQuit(app: F.safari, pid: 5),
        ]
        for step in steps {
            #expect(!step.description.isEmpty)
            #expect(step.description == "\(step)")
        }
        #expect(steps[0].description == "launch Slack (2 windows)")
        #expect(steps[3].description.contains("Desktop 2"))
        #expect(steps[4].description.contains("800x600 at 100,100"))
        #expect(target.label == "Google Chrome \"Inbox\" (window 84)")
        #expect(steps.map(\.phase) == [.launch, .exitFullScreen, .unminimize, .moveToDesktop, .setFrame, .enterFullScreen,
                                       .minimize, .raise, .otherApps, .otherApps])
    }

    @Test func outlineListsPhasesWarningsAndMissingWindows() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2)), F.snap(2, F.slack)])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome, spaces: [11])], trusted: false))
        let text = plan.outline
        #expect(text.contains("Restore plan for \"Work\""))
        #expect(text.contains("Warnings"))
        #expect(text.contains("Launch apps (1):"))
        #expect(text.contains("Move to Desktop (1):"))
        #expect(text.contains("Not found (1):"))
    }

    @Test func removingAPhaseKeepsTheRest() {
        let profile = F.profile([F.snap(1, F.slack), F.snap(2, F.chrome, placement: .desktop(number: 2))])
        let plan = F.plan(profile, F.scan([F.live(101, F.chrome)]))
        let rest = plan.removing(.launch)
        #expect(plan.steps(in: .launch).count == 1)
        #expect(rest.steps(in: .launch).isEmpty)
        #expect(rest.steps.count == plan.steps.count - 1)
        #expect(rest.unmatched == plan.unmatched)
    }

    @Test func planningIsDeterministic() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2), z: 2), F.snap(2, F.slack, z: 1),
                                 F.snap(3, F.notes, minimized: true, z: 0)])
        let scan = F.scan([F.live(101, F.chrome), F.live(102, F.slack, frame: .zero), F.live(103, F.notes)])
        #expect(F.plan(profile, scan) == F.plan(profile, scan))
    }
}
