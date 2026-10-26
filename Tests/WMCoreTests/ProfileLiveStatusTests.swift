import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Fixture plans for `ProfileLiveStatus`, made by the real planner from small fake profiles and live windows.
@Suite struct ProfileLiveStatusTests {
    typealias F = RestoreFixtures

    /// Same pipeline as `RestoreFixtures.plan`, with the engine's `addMissingDesktops` opt-in.
    static func plan(_ profile: Profile, _ scan: WorkspaceScan, addMissingDesktops: Bool) -> RestorePlan {
        let displayMatch = DisplayMap.match(saved: profile.displays, current: scan.displays)
        let snapshots = RestorePlanner.remap(profile.windows, savedDisplays: profile.displays, displayMatch: displayMatch)
        let match = WindowMatcher.match(snapshots: snapshots, live: scan.windows)
        return RestorePlanner.plan(profile: profile, scan: scan, displayMatch: displayMatch, match: match,
                                   options: profile.options, addMissingDesktops: addMissingDesktops)
    }

    static func status(_ profile: Profile, _ scan: WorkspaceScan) -> ProfileLiveStatus {
        ProfileLiveStatus(profile: profile, plan: F.plan(profile, scan))
    }

    static let shifted = F.defaultFrame.offsetBy(dx: 500, dy: 0)

    // MARK: Per window

    @Test func matchedWindowWithNothingToDoIsInPlace() {
        let profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.slack, frame: F.defaultFrame.offsetBy(dx: 300, dy: 300))])
        let scan = F.scan([F.live(101, F.chrome), F.live(102, F.slack, frame: F.defaultFrame.offsetBy(dx: 300, dy: 300))])
        let result = Self.status(profile, scan)
        #expect(result.windows == [F.sid(1): .inPlace, F.sid(2): .inPlace])
        #expect(result.spaces.isEmpty)
        #expect(result.summary == ProfileLiveSummary(inPlace: 2))
    }

    @Test func raiseAloneIsStillInPlace() {
        // Both windows are where they should be, only the stacking order differs.
        let profile = F.profile([F.snap(1, F.chrome, z: 0), F.snap(2, F.slack, z: 1)])
        let scan = F.scan([F.live(102, F.slack), F.live(101, F.chrome)])
        let plan = F.plan(profile, scan)
        #expect(plan.steps.contains { if case .raise = $0 { return true } else { return false } })
        #expect(Self.status(profile, scan).windows == [F.sid(1): .inPlace, F.sid(2): .inPlace])
    }

    @Test func frameChangeIsWillMove() {
        let profile = F.profile([F.snap(1, F.chrome)])
        let scan = F.scan([F.live(101, F.chrome, frame: Self.shifted)])
        #expect(Self.status(profile, scan).windows == [F.sid(1): .willMove])
    }

    @Test func desktopChangeIsWillMove() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2))])
        let scan = F.scan([F.live(101, F.chrome, spaces: [11])])
        #expect(Self.status(profile, scan).windows == [F.sid(1): .willMove])
    }

    @Test func minimizeAndFullScreenChangesAreWillMove() {
        let minimize = F.profile([F.snap(1, F.chrome, minimized: true)])
        #expect(Self.status(minimize, F.scan([F.live(101, F.chrome)])).windows == [F.sid(1): .willMove])

        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let enter = F.profile([F.snap(1, F.chrome, frame: screen, placement: .fullScreen(position: 2), fullScreen: true)])
        #expect(Self.status(enter, F.scan([F.live(101, F.chrome)])).windows == [F.sid(1): .willMove])
    }

    @Test func windowOfALaunchedAppIsWillLaunch() {
        let profile = F.profile([F.snap(1, F.slack), F.snap(2, F.slack, index: 1), F.snap(3, F.chrome)])
        let scan = F.scan([F.live(101, F.chrome)])
        let result = Self.status(profile, scan)
        #expect(result.windows[F.sid(1)] == .willLaunch)
        #expect(result.windows[F.sid(2)] == .willLaunch)
        #expect(result.windows[F.sid(3)] == .inPlace)
        #expect(result.summary.willLaunch == 2)
        #expect(result.summary.appsToLaunch == 1)
        #expect(result.summary.notFound == 0)
    }

    @Test func unmatchedWindowKeepsThePlannersReason() {
        // Chrome runs with one window; the profile wants two.
        let profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.chrome, index: 1)])
        let scan = F.scan([F.live(101, F.chrome)])
        let result = Self.status(profile, scan)
        let reason = "the app has fewer windows open than the profile"
        #expect(result.windows[F.sid(2)] == .notFound(reason: reason))
        #expect(result.summary.notFound == 1)
        #expect(result.summary.appsToLaunch == 0)
    }

    @Test func notFoundWhenLaunchingIsSwitchedOff() {
        let profile = F.profile([F.snap(1, F.slack)], options: ProfileOptions(launchMissingApps: false))
        let result = Self.status(profile, F.scan([]))
        guard case .notFound(let reason) = result.windows[F.sid(1)] else {
            Issue.record("expected notFound")
            return
        }
        #expect(reason.contains("switched off"))
        #expect(result.summary == ProfileLiveSummary(notFound: 1))
    }

    @Test func windowWithRestoreOffIsNotRestoredWhetherOrNotItIsLive() {
        let profile = F.profile([F.snap(1, F.chrome, restore: false), F.snap(2, F.notes, restore: false), F.snap(3, F.slack)])
        // Chrome is open at another place, Notes is not open at all, Slack is in place.
        let scan = F.scan([F.live(101, F.chrome, frame: Self.shifted), F.live(103, F.slack)])
        let result = Self.status(profile, scan)
        #expect(result.windows[F.sid(1)] == .notRestored)
        #expect(result.windows[F.sid(2)] == .notRestored)
        #expect(result.windows[F.sid(3)] == .inPlace)
        #expect(result.summary == ProfileLiveSummary(inPlace: 1, notRestored: 2))
    }

    // MARK: Desktops

    @Test func missingDesktopIsASpaceStatusThatStaysMissing() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 3))])
        let scan = F.scan([F.live(101, F.chrome, spaces: [11])])
        let result = Self.status(profile, scan)
        #expect(result.spaces == [SpaceKey(displayUUID: F.uuidA, desktopNumber: 3):
                                    .desktopMissing(available: 2, willBeAdded: false, snapshotIDs: [F.sid(1)])])
        #expect(result.summary.missingDesktops == 1)
        // The window stays where it is, so it is in place.
        #expect(result.windows[F.sid(1)] == .inPlace)
    }

    @Test func missingDesktopIsMarkedWillBeAddedWhenThePlanAddsIt() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 3))])
        let scan = F.scan([F.live(101, F.chrome, spaces: [11])])
        let plan = Self.plan(profile, scan, addMissingDesktops: true)
        #expect(plan.steps.contains { if case .addDesktop = $0 { return true } else { return false } })
        let result = ProfileLiveStatus(profile: profile, plan: plan)
        #expect(result.spaces == [SpaceKey(displayUUID: F.uuidA, desktopNumber: 3):
                                    .desktopMissing(available: 2, willBeAdded: true, snapshotIDs: [F.sid(1)])])
    }

    @Test func desktopThatExistsHasNoSpaceStatus() {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2))])
        let result = Self.status(profile, F.scan([F.live(101, F.chrome, spaces: [12], current: false)]))
        #expect(result.spaces.isEmpty)
        #expect(result.summary.missingDesktops == 0)
    }

    // MARK: Summary

    @Test func summaryCountsEveryKindOfWindow() {
        let profile = F.profile([
            F.snap(1, F.chrome),                                             // in place
            F.snap(2, F.notes, frame: F.defaultFrame.offsetBy(dx: 0, dy: 50)), // will move
            F.snap(3, F.slack),                                              // will launch
            F.snap(4, F.slack, index: 1),                                    // will launch
            F.snap(5, F.safari), F.snap(6, F.safari, index: 1),              // one in place, one not found
            F.snap(7, F.mail, placement: .desktop(number: 3)),               // Desktop missing, stays put
            F.snap(8, F.finder, restore: false),                             // not restored
        ])
        let scan = F.scan([
            F.live(101, F.chrome),
            F.live(102, F.notes),
            F.live(103, F.safari),
            F.live(104, F.mail, spaces: [11]),
        ])
        let result = Self.status(profile, scan)
        #expect(result.summary == ProfileLiveSummary(inPlace: 3, willMove: 1, willLaunch: 2, appsToLaunch: 1,
                                                     notFound: 1, notRestored: 1, missingDesktops: 1))
        #expect(result.summary.windowCount == profile.windows.count)
        #expect(result.windows.count == profile.windows.count)
    }

    @Test func emptyPlanIsAllInPlace() {
        let profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.notes)])
        let scan = F.scan([F.live(101, F.chrome), F.live(102, F.notes)])
        let plan = F.plan(profile, scan)
        #expect(plan.isEmpty)
        let result = ProfileLiveStatus(profile: profile, plan: plan)
        #expect(result.windows == [F.sid(1): .inPlace, F.sid(2): .inPlace])
        #expect(result.summary == ProfileLiveSummary(inPlace: 2))
    }
}
