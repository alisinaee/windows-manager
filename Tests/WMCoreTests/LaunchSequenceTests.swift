import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// PM5: launch order logic (`LaunchSequence`): request order, validation, worst-case duration and editing.
@Suite struct LaunchSequenceTests {
    // MARK: Fixtures

    static let xcode = AppRef(bundleID: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")
    static let slack = AppRef(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", path: nil)
    static let music = AppRef(bundleID: "com.apple.Music", name: "Music", path: nil)
    static let notes = AppRef(bundleID: "com.apple.Notes", name: "Notes", path: nil)

    static func window(_ app: AppRef, index: Int = 0, restore: Bool = true) -> WindowSnapshot {
        WindowSnapshot(app: app, indexInApp: index, displayUUID: "DISPLAY-A",
                       frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                       relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 1),
                       placement: .desktop(number: 1), restore: restore)
    }

    /// Captured order of apps: Slack, Xcode, Notes (Music has no windows).
    static func profile(plan: LaunchPlan?) -> Profile {
        Profile(name: "Work", createdAt: ProfileStoreTests.t0, monitorSetKey: "one", displays: [], spaces: [],
                windows: [
                    window(slack),
                    window(xcode, index: 0),
                    window(xcode, index: 1),
                    window(xcode, index: 2, restore: false),
                    window(notes),
                ],
                launchPlan: plan)
    }

    static func ids(_ requests: [ProfileLaunchRequest]) -> [String] {
        requests.map { $0.app.name }
    }

    // MARK: Order

    @Test func noPlanLaunchesEveryAppInParallelInCapturedOrder() {
        let requests = LaunchSequence.order(Self.profile(plan: nil))
        #expect(Self.ids(requests) == ["Slack", "Xcode", "Notes"])
        #expect(requests.allSatisfy { $0.mode == .parallel && $0.timeout == nil && $0.delayAfter == 0 })
        #expect(requests.map(\.minWindows) == [1, 2, 1])
    }

    @Test func enabledItemsComeFirstInPlanOrderThenTheRestInCapturedOrder() {
        let plan = LaunchPlan(mode: .sequential, items: [
            LaunchItem(app: Self.notes),
            LaunchItem(app: Self.xcode, delayAfter: 3),
        ])
        let requests = LaunchSequence.order(Self.profile(plan: plan))
        #expect(Self.ids(requests) == ["Notes", "Xcode", "Slack"])
        #expect(requests[1].delayAfter == 3)
        #expect(requests[2].delayAfter == 0)
        #expect(requests[2].timeout == nil)
    }

    @Test func disabledItemsAreExcludedAndTheirAppsAreNotLaunchedByTheDefaultOrder() {
        let plan = LaunchPlan(mode: .sequential, items: [
            LaunchItem(app: Self.slack, enabled: false),
            LaunchItem(app: Self.xcode),
        ])
        let requests = LaunchSequence.order(Self.profile(plan: plan))
        #expect(Self.ids(requests) == ["Xcode", "Notes"])
    }

    @Test func requestsCarryWaitTimeoutDelayAndMode() {
        let plan = LaunchPlan(mode: .sequential, items: [
            LaunchItem(app: Self.xcode, wait: .appReady, delayAfter: 2, timeout: 30),
            LaunchItem(app: Self.slack, wait: .windows, delayAfter: 1.5, timeout: nil),
        ])
        let requests = LaunchSequence.order(Self.profile(plan: plan))
        #expect(requests[0] == ProfileLaunchRequest(app: Self.xcode, minWindows: 0, timeout: 30, delayAfter: 2,
                                             mode: .sequential, wait: .appReady))
        #expect(requests[1] == ProfileLaunchRequest(app: Self.slack, minWindows: 1, timeout: nil, delayAfter: 1.5,
                                             mode: .sequential, wait: .windows))
    }

    @Test func minWindowsCountsOnlyRestorableSnapshotsOfThatApp() {
        // Xcode has three snapshots, one of them unticked (restore == false), so two are expected.
        let plan = LaunchPlan(mode: .sequential, items: [LaunchItem(app: Self.xcode)])
        let requests = LaunchSequence.order(Self.profile(plan: plan))
        #expect(requests[0].minWindows == 2)
    }

    @Test func launchOnlyAndWithoutWindowsItemsWaitForNoWindows() {
        let plan = LaunchPlan(mode: .sequential, items: [
            LaunchItem(app: Self.music, withoutWindows: true),
            LaunchItem(app: Self.xcode, withoutWindows: true),
        ])
        let requests = LaunchSequence.order(Self.profile(plan: plan))
        #expect(requests.map(\.minWindows) == [0, 0, 1, 1])
        #expect(Self.ids(requests) == ["Music", "Xcode", "Slack", "Notes"])
    }

    @Test func launchOnlyAppsAreNotLaunchedTwice() {
        // Music is launch-only, so it is in `launchApps` too. The plan lists it once.
        let plan = LaunchPlan(mode: .parallel, items: [LaunchItem(app: Self.music, withoutWindows: true)])
        let requests = LaunchSequence.order(Self.profile(plan: plan))
        #expect(requests.filter { $0.app.name == "Music" }.count == 1)
    }

    @Test func duplicateEnabledEntriesLaunchOnce() {
        let plan = LaunchPlan(mode: .sequential, items: [
            LaunchItem(app: Self.xcode, delayAfter: 1),
            LaunchItem(app: Self.xcode, delayAfter: 5),
        ])
        let requests = LaunchSequence.order(Self.profile(plan: plan))
        #expect(Self.ids(requests) == ["Xcode", "Slack", "Notes"])
        #expect(requests[0].delayAfter == 1)
    }

    // MARK: Validation

    @Test func cleanPlanHasNoIssues() {
        let plan = LaunchPlan(mode: .sequential, items: [
            LaunchItem(app: Self.xcode, delayAfter: 2, timeout: 30),
            LaunchItem(app: Self.music, withoutWindows: true),
        ])
        let issues = LaunchSequence.validate(plan: plan, profile: Self.profile(plan: plan),
                                             installedApps: ["com.apple.dt.xcode", "com.apple.music"])
        #expect(issues.isEmpty)
    }

    @Test func duplicateAppIsReported() {
        let plan = LaunchPlan(mode: .sequential, items: [LaunchItem(app: Self.xcode), LaunchItem(app: Self.xcode)])
        let issues = LaunchSequence.validate(plan: plan, profile: Self.profile(plan: plan))
        let duplicates = issues.filter { $0.kind == .duplicateApp }
        #expect(duplicates.count == 1)
        #expect(duplicates.first?.itemID == "com.apple.dt.xcode")
        #expect(duplicates.first?.message == "Xcode is listed more than once in the launch order. Remove one of the entries.")
    }

    @Test func notInstalledIsReportedOnlyWhenASetIsGiven() {
        let plan = LaunchPlan(mode: .sequential, items: [LaunchItem(app: Self.slack)])
        let profile = Self.profile(plan: plan)

        #expect(LaunchSequence.validate(plan: plan, profile: profile, installedApps: nil).isEmpty)

        let issues = LaunchSequence.validate(plan: plan, profile: profile, installedApps: ["com.apple.Notes"])
        #expect(issues.map(\.kind) == [.notInstalled])
        #expect(issues.first?.message.contains("Slack is not installed") == true)

        let installed = LaunchSequence.validate(plan: plan, profile: profile,
                                                installedApps: ["COM.TINYSPECK.SLACKMACGAP"])
        #expect(installed.isEmpty)
    }

    @Test func appWithoutBundleIdIsNotCheckedAgainstInstalledApps() {
        let legacyApp = AppRef(bundleID: nil, name: "Legacy", path: "/Applications/Legacy.app")
        let plan = LaunchPlan(mode: .sequential, items: [LaunchItem(app: legacyApp, withoutWindows: true)])
        #expect(LaunchSequence.validate(plan: plan, profile: Self.profile(plan: plan), installedApps: []).isEmpty)
    }

    @Test func delayIsIgnoredInParallelMode() {
        let plan = LaunchPlan(mode: .parallel, items: [LaunchItem(app: Self.xcode, delayAfter: 4)])
        let issues = LaunchSequence.validate(plan: plan, profile: Self.profile(plan: plan))
        #expect(issues.map(\.kind) == [.delayIgnoredInParallel])
        #expect(issues.first?.message.contains("runs in parallel, so the delay is ignored") == true)

        let sequential = LaunchPlan(mode: .sequential, items: [LaunchItem(app: Self.xcode, delayAfter: 4)])
        #expect(LaunchSequence.validate(plan: sequential, profile: Self.profile(plan: sequential)).isEmpty)
    }

    @Test func timeoutShorterThanDelayIsReported() {
        let plan = LaunchPlan(mode: .sequential, items: [LaunchItem(app: Self.xcode, delayAfter: 20, timeout: 10)])
        let issues = LaunchSequence.validate(plan: plan, profile: Self.profile(plan: plan))
        #expect(issues.map(\.kind) == [.timeoutShorterThanDelay])
        #expect(issues.first?.message == "Xcode times out after 10 s, before its 20 s delay ends. "
                    + "Raise the timeout or shorten the delay.")
    }

    @Test func timeoutEqualToDelayIsFine() {
        let plan = LaunchPlan(mode: .sequential, items: [LaunchItem(app: Self.xcode, delayAfter: 10, timeout: 10)])
        #expect(LaunchSequence.validate(plan: plan, profile: Self.profile(plan: plan)).isEmpty)
    }

    @Test func planItemWithoutWindowsThatIsNotLaunchOnlyIsReported() {
        let plan = LaunchPlan(mode: .sequential, items: [LaunchItem(app: Self.music)])
        let issues = LaunchSequence.validate(plan: plan, profile: Self.profile(plan: plan))
        #expect(issues.map(\.kind) == [.noWindowsNotLaunchOnly])
        #expect(issues.first?.itemID == "com.apple.music")
    }

    @Test func disabledItemWithoutWindowsIsNotReported() {
        let plan = LaunchPlan(mode: .sequential, items: [LaunchItem(app: Self.music, enabled: false)])
        #expect(LaunchSequence.validate(plan: plan, profile: Self.profile(plan: plan)).isEmpty)
    }

    // MARK: Worst-case duration

    @Test func worstCaseIsSumOfTimeoutAndDelayInSequentialMode() {
        let plan = LaunchPlan(mode: .sequential, items: [
            LaunchItem(app: Self.xcode, delayAfter: 2, timeout: 30),
            LaunchItem(app: Self.slack, delayAfter: 5, timeout: nil),
            LaunchItem(app: Self.notes, enabled: false, delayAfter: 60, timeout: 120),
        ])
        // 30 + 2 + (20 default) + 5; the disabled item is never launched.
        #expect(LaunchSequence.worstCaseDuration(plan: plan) == 57)
    }

    @Test func worstCaseIsLongestTimeoutInParallelMode() {
        let plan = LaunchPlan(mode: .parallel, items: [
            LaunchItem(app: Self.xcode, delayAfter: 50, timeout: 30),
            LaunchItem(app: Self.slack, timeout: nil),
            LaunchItem(app: Self.notes, enabled: false, timeout: 120),
        ])
        #expect(LaunchSequence.worstCaseDuration(plan: plan) == 30)
    }

    @Test func worstCaseOfEmptyPlanIsZero() {
        #expect(LaunchSequence.worstCaseDuration(plan: LaunchPlan()) == 0)
        #expect(LaunchSequence.worstCaseDuration(plan: LaunchPlan(mode: .parallel)) == 0)
    }

    // MARK: Editing

    static let threeItems = LaunchPlan(mode: .sequential, items: [
        LaunchItem(app: LaunchSequenceTests.xcode), LaunchItem(app: LaunchSequenceTests.slack),
        LaunchItem(app: LaunchSequenceTests.notes),
    ])

    @Test func movedReordersAndClampsDestination() {
        let down = LaunchSequence.moved(Self.threeItems, from: 0, to: 2)
        #expect(down.items.map(\.app.name) == ["Slack", "Notes", "Xcode"])

        let up = LaunchSequence.moved(Self.threeItems, from: 2, to: 0)
        #expect(up.items.map(\.app.name) == ["Notes", "Xcode", "Slack"])

        let clamped = LaunchSequence.moved(Self.threeItems, from: 0, to: 99)
        #expect(clamped.items.map(\.app.name) == ["Slack", "Notes", "Xcode"])

        let outOfRange = LaunchSequence.moved(Self.threeItems, from: 7, to: 0)
        #expect(outOfRange == Self.threeItems)
    }

    @Test func toggledFlipsEnabledForOneItem() {
        let toggled = LaunchSequence.toggled(Self.threeItems, id: "com.tinyspeck.slackmacgap")
        #expect(toggled.items.map(\.enabled) == [true, false, true])
        #expect(LaunchSequence.toggled(toggled, id: "com.tinyspeck.slackmacgap") == Self.threeItems)
        #expect(LaunchSequence.toggled(Self.threeItems, id: "missing") == Self.threeItems)
    }

    @Test func settingDelayClampsToRange() {
        let plan = LaunchSequence.settingDelay(Self.threeItems, id: "com.apple.dt.xcode", 500)
        #expect(plan.items[0].delayAfter == LaunchItem.delayRange.upperBound)

        let negative = LaunchSequence.settingDelay(Self.threeItems, id: "com.apple.dt.xcode", -3)
        #expect(negative.items[0].delayAfter == 0)

        let nan = LaunchSequence.settingDelay(Self.threeItems, id: "com.apple.dt.xcode", .nan)
        #expect(nan.items[0].delayAfter == 0)

        let untouched = LaunchSequence.settingDelay(Self.threeItems, id: "com.apple.dt.xcode", 4)
        #expect(untouched.items[1] == Self.threeItems.items[1])
    }

    @Test func settingTimeoutClampsAndNilKeepsTheDefault() {
        let low = LaunchSequence.settingTimeout(Self.threeItems, id: "com.tinyspeck.slackmacgap", 1)
        #expect(low.items[1].timeout == LaunchItem.timeoutRange.lowerBound)

        let high = LaunchSequence.settingTimeout(Self.threeItems, id: "com.tinyspeck.slackmacgap", 900)
        #expect(high.items[1].timeout == LaunchItem.timeoutRange.upperBound)

        let set = LaunchSequence.settingTimeout(high, id: "com.tinyspeck.slackmacgap", nil)
        #expect(set.items[1].timeout == nil)
    }

    @Test func settingWaitChangesOnlyTheMatchingItem() {
        let plan = LaunchSequence.settingWait(Self.threeItems, id: "com.apple.notes", .appReady)
        #expect(plan.items.map(\.wait) == [.windows, .windows, .appReady])
    }
}
