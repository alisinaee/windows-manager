import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@MainActor
@Suite struct RestoreScopeEngineTests {
    typealias F = RestoreFixtures

    static let far = CGRect(x: 900, y: 500, width: 400, height: 300)

    /// Chrome on A Desktop 1, Slack on A Desktop 2, Safari on B Desktop 1, Notes launch-only target (not running).
    /// Live: Chrome, Slack, Safari all displaced; Mail is running and not in the profile.
    static func fixture(hideOthers: Bool = true) -> (Profile, WorkspaceScan) {
        var options = ProfileOptions()
        if hideOthers { options.otherApps = .hide }
        let profile = F.profile([
            F.snap(1, F.chrome, frame: CGRect(x: 100, y: 100, width: 800, height: 600), placement: .desktop(number: 1)),
            F.snap(2, F.slack, frame: CGRect(x: 200, y: 200, width: 500, height: 400), placement: .desktop(number: 2)),
            F.snap(3, F.safari, display: F.uuidB, frame: CGRect(x: 2000, y: 100, width: 800, height: 600),
                   placement: .desktop(number: 1)),
            F.snap(4, F.notes, frame: CGRect(x: 300, y: 300, width: 500, height: 400), placement: .desktop(number: 1)),
        ], options: options)
        let scan = F.scan([
            F.live(101, F.chrome, frame: far, spaces: [11]),
            F.live(102, F.slack, frame: far, spaces: [12], current: false),
            F.live(103, F.safari, display: F.uuidB, frame: CGRect(x: 2100, y: 600, width: 300, height: 300), spaces: [21]),
            F.live(105, F.mail, frame: far, spaces: [11]),
        ])
        return (profile, scan)
    }

    static func engine(_ env: FakeRestoreEnvironment,
                       limits: ((String?, String?) -> WindowResizeLimits?)? = nil) -> RestoreEngine {
        var configuration = RestoreEngine.Configuration()
        configuration.settleDelay = 0
        return RestoreEngine(environment: env, configuration: configuration, desktopAdder: FakeDesktopAdder(count: 2),
                             sizeLimitProvider: limits)
    }

    @Test func wholeScopeIsUnchanged() async {
        let (profile, scan) = Self.fixture()
        let a = FakeRestoreEnvironment(scans: [scan])
        let b = FakeRestoreEnvironment(scans: [scan])
        let plain = await Self.engine(a).run(profile)
        let whole = await Self.engine(b).run(profile, scope: .whole)
        #expect(a.actions == b.actions)
        #expect(a.actions.contains("hide:1105"))
        #expect(plain.summary == whole.summary)
        #expect(whole.scopeSummary == nil)
        #expect(whole.failure == nil)
    }

    @Test func desktopScopeTouchesOnlyThatDesktop() async {
        let (profile, scan) = Self.fixture()
        let env = FakeRestoreEnvironment(scans: [scan])
        let scope = RestoreScope(desktops: [SpaceRef(displayUUID: F.uuidA, desktopNumber: 2)])
        let report = await Self.engine(env).run(profile, scope: scope)
        #expect(env.actions.contains("setFrame:102"))
        #expect(!env.actions.contains { $0.hasSuffix(":101") || $0.hasSuffix(":103") || $0.hasSuffix(":105") })
        #expect(!env.actions.contains { $0.hasPrefix("hide") || $0.hasPrefix("launch") })
        #expect(report.windows.count == 1)
        #expect(report.scopeSummary?.contains("Desktop 2") == true)
        #expect(report.summary.contains("Desktop 2"))
    }

    @Test func appScopeLaunchesOnlyItsApps() async {
        let (profile, scan) = Self.fixture()
        let env = FakeRestoreEnvironment(scans: [scan])
        let report = await Self.engine(env).run(profile, scope: RestoreScope(apps: [F.notes.bundleID!]))
        #expect(env.actions.contains { $0.hasPrefix("launch:Notes") })
        #expect(!env.actions.contains { $0.hasPrefix("hide") })
        #expect(!env.actions.contains("setFrame:101"))
        #expect(report.scopeSummary != nil)

        let other = FakeRestoreEnvironment(scans: [scan])
        _ = await Self.engine(other).run(profile, scope: RestoreScope(apps: [F.chrome.bundleID!]))
        #expect(!other.actions.contains { $0.hasPrefix("launch") })
        #expect(other.actions.contains("setFrame:101"))
    }

    @Test func monitorScopePreviewHasNoOtherAppsStep() async {
        let (profile, scan) = Self.fixture()
        let env = FakeRestoreEnvironment(scans: [scan])
        let plan = await Self.engine(env).preview(profile: profile, scope: RestoreScope(displays: [F.uuidB]))
        #expect(plan.steps.map(\.kind).filter { $0 != "raise" } == ["setFrame"])
        #expect(plan.steps.compactMap(\.target?.windowID) == [103])
        #expect(plan.scopeSummary?.hasPrefix("Monitor") == true)
        #expect(env.actions.isEmpty)
        let whole = await Self.engine(FakeRestoreEnvironment(scans: [scan])).preview(profile: profile)
        #expect(whole.scopeSummary == nil)
        #expect(whole.steps.contains { $0.kind == "hideApp" })
    }

    @Test func emptyScopeFailsBeforeTouchingAnything() async {
        let (profile, scan) = Self.fixture()
        let env = FakeRestoreEnvironment(scans: [scan])
        let scope = RestoreScope(desktops: [SpaceRef(displayUUID: F.uuidA, desktopNumber: 9)])
        let report = await Self.engine(env).run(profile, scope: scope)
        #expect(report.failure == ScopeError.emptyScope.errorDescription)
        #expect(!report.isClean)
        #expect(env.calls.isEmpty)
        #expect(report.summary == ScopeError.emptyScope.errorDescription)
        let plan = await Self.engine(env).preview(profile: profile, scope: scope)
        #expect(plan.steps.isEmpty && !plan.warnings.isEmpty)
        #expect(env.calls.isEmpty)
    }

    @Test func missingMonitorWarnsAndTargetsNothing() async {
        let (profile, _) = Self.fixture(hideOthers: false)
        // No monitor at all is connected: nothing can be matched, and the main monitor is not a fallback.
        let scan = F.scan([F.live(103, F.safari, display: nil, frame: Self.far)], displays: [])
        let env = FakeRestoreEnvironment(scans: [scan])
        let report = await Self.engine(env).run(profile, scope: RestoreScope(displays: [F.uuidB]))
        #expect(!env.actions.contains { $0.hasPrefix("setFrame") })
        #expect(report.warnings.contains { $0.contains("not connected") })
    }

    // MARK: Size limits

    @Test func cachedLimitsGivePositionOnlyStep() {
        let profile = F.profile([F.snap(1, F.chrome, frame: CGRect(x: 100, y: 100, width: 800, height: 600))])
        let scan = F.scan([F.live(101, F.chrome, frame: CGRect(x: 500, y: 500, width: 700, height: 600))])
        let displayMatch = DisplayMap.match(saved: profile.displays, current: scan.displays)
        let snapshots = RestorePlanner.remap(profile.windows, savedDisplays: profile.displays, displayMatch: displayMatch)
        let match = WindowMatcher.match(snapshots: snapshots, live: scan.windows)
        let limits = WindowResizeLimits(fixedWidth: true, fixedHeight: false, maxSize: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 450))

        let without = RestorePlanner.plan(profile: profile, scan: scan, displayMatch: displayMatch, match: match,
                                          options: profile.options)
        let with = RestorePlanner.plan(profile: profile, scan: scan, displayMatch: displayMatch, match: match,
                                       options: profile.options, cachedLimits: { _, _ in limits })
        guard case .setFrame(_, let plain, _, _) = without.steps[0],
              case .setFrame(let target, let clamped, _, _) = with.steps[0] else {
            Issue.record("expected setFrame steps"); return
        }
        #expect(plain.size == CGSize(width: 800, height: 600))
        #expect(clamped.origin == CGPoint(x: 100, y: 100))
        #expect(clamped.size == CGSize(width: 700, height: 450))
        #expect(with.sizeNotes[target.snapshotID]?.contains("fixed width") == true)
        #expect(with.warnings.contains { $0.contains("cannot change size") })
        // The profile's own limits win over the cache.
        var own = profile
        own.windows[0].resizeLimits = WindowResizeLimits(fixedWidth: true, fixedHeight: true)
        let owned = RestorePlanner.plan(profile: own, scan: scan, displayMatch: displayMatch, match: match,
                                        options: own.options, cachedLimits: { _, _ in limits })
        guard case .setFrame(_, let both, _, _) = owned.steps[0] else { Issue.record("no step"); return }
        #expect(both.size == CGSize(width: 700, height: 600))
    }

    @Test func engineUsesInjectedLimitProviderAndNotesTheStep() async {
        let profile = F.profile([F.snap(1, F.chrome, frame: CGRect(x: 100, y: 100, width: 800, height: 600))])
        let scan = F.scan([F.live(101, F.chrome, frame: CGRect(x: 500, y: 500, width: 700, height: 600))])
        let env = FakeRestoreEnvironment(scans: [scan])
        let engine = Self.engine(env) { bundle, _ in
            bundle == F.chrome.bundleID ? WindowResizeLimits(fixedWidth: true) : nil
        }
        let plan = await engine.preview(profile: profile)
        guard case .setFrame(_, let frame, _, _) = plan.steps[0] else { Issue.record("no step"); return }
        #expect(frame.width == 700)
        let report = await engine.run(profile)
        #expect(report.steps.first { $0.kind == "setFrame" }?.note?.contains("size not changed") == true)
    }
}
