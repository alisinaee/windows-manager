import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// A restore environment that touches nothing: it answers from canned scans and writes every call it gets into
/// `calls`, so a test can read what the engine did and in which order.
@MainActor
final class FakeRestoreEnvironment: RestoreEnvironment {
    /// What `scan()` returns, one entry per call; the last one repeats.
    var scans: [WorkspaceScan]
    var launchResults: [LaunchResult] = []
    /// Windows with no Accessibility element.
    var unreachable: Set<UInt32> = []
    /// Call name (as written to `calls`, e.g. "setFrame:101") -> failure text.
    var failures: [String: String] = [:]
    /// Call name -> seconds the call takes (it ends early, failed, when its task is cancelled).
    var delays: [String: TimeInterval] = [:]
    /// Successive answers of `frameOf` per window id; when empty the last placed frame is answered.
    var frameReadings: [UInt32: [CGRect]] = [:]
    /// When set, `setFrame` reports this frame instead of the requested one (a window with a minimum size).
    var biggerFrame: CGRect?

    private(set) var calls: [String] = []
    private(set) var sleeps: [TimeInterval] = []
    private(set) var scanCount = 0
    private(set) var maxActive = 0
    private var active = 0
    private var lastFrame: [UInt32: CGRect] = [:]

    init(scans: [WorkspaceScan]) {
        self.scans = scans
    }

    /// The calls that changed something (without scans, element lookups and sleeps).
    var actions: [String] {
        calls.filter { !($0 == "scan" || $0.hasPrefix("element:") || $0.hasPrefix("sleep:")) }
    }

    func count(_ name: String) -> Int { calls.filter { $0 == name }.count }

    private func act(_ name: String, frame: CGRect? = nil) async -> RestoreActionResult {
        calls.append(name)
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        if let delay = delays[name] {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return .failure("cancelled")
            }
        }
        if let reason = failures[name] { return .failure(reason) }
        return .ok(frame: frame)
    }

    func scan() async -> WorkspaceScan {
        calls.append("scan")
        defer { scanCount += 1 }
        return scans[min(scanCount, scans.count - 1)]
    }

    func launchAll(_ requests: [LaunchRequest]) async -> [LaunchResult] {
        calls.append("launch:" + requests.map(\.app.name).joined(separator: ","))
        if !launchResults.isEmpty { return launchResults }
        return requests.map { LaunchResult(app: $0.app, status: .launched, windowCount: $0.minWindows) }
    }

    func element(for target: RestoreTarget) -> WindowHandle? {
        calls.append("element:\(target.windowID)")
        return unreachable.contains(target.windowID) ? nil : WindowHandle(windowID: target.windowID, pid: target.pid)
    }

    func setFrame(_ handle: WindowHandle, to frame: CGRect) async -> RestoreActionResult {
        let result = await act("setFrame:\(handle.windowID)", frame: biggerFrame ?? frame)
        if result.succeeded { lastFrame[handle.windowID] = biggerFrame ?? frame }
        return result
    }

    func setFullScreen(_ handle: WindowHandle, _ on: Bool, timeout: TimeInterval) async -> RestoreActionResult {
        await act("\(on ? "enter" : "exit")FullScreen:\(handle.windowID)")
    }

    func minimize(_ handle: WindowHandle) async -> RestoreActionResult { await act("minimize:\(handle.windowID)") }
    func unminimize(_ handle: WindowHandle) async -> RestoreActionResult { await act("unminimize:\(handle.windowID)") }
    func raise(_ handle: WindowHandle, app: AppRef) async -> RestoreActionResult { await act("raise:\(handle.windowID)") }

    func moveToDesktop(windowID: UInt32, spaceID: UInt64) async -> RestoreActionResult {
        await act("moveToDesktop:\(windowID)->\(spaceID)")
    }

    func hideApp(pid: Int32, app: AppRef) async -> RestoreActionResult { await act("hide:\(pid)") }

    func frameOf(_ handle: WindowHandle) -> CGRect? {
        if var queued = frameReadings[handle.windowID], !queued.isEmpty {
            let next = queued.removeFirst()
            frameReadings[handle.windowID] = queued
            return next
        }
        return lastFrame[handle.windowID]
    }

    func sleep(_ seconds: TimeInterval) async {
        sleeps.append(seconds)
        calls.append("sleep:\(seconds)")
    }
}

/// Lets a progress callback cancel the task that runs the engine.
@MainActor
final class TaskBox {
    var task: Task<RestoreReport, Never>?
}

@MainActor
@Suite struct RestoreEngineTests {
    typealias F = RestoreFixtures

    static func engine(_ env: FakeRestoreEnvironment, stepTimeout: TimeInterval = 5) -> RestoreEngine {
        var configuration = RestoreEngine.Configuration()
        configuration.stepTimeout = stepTimeout
        return RestoreEngine(environment: env, configuration: configuration)
    }

    static let screenA = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    static let screenB = CGRect(x: 1920, y: 0, width: 2560, height: 1440)

    // MARK: Happy path

    @Test func happyPathRunsEveryPhaseInOrder() async {
        let slackFrame = CGRect(x: 200, y: 200, width: 500, height: 400)
        let safariFrame = CGRect(x: 400, y: 300, width: 600, height: 500)
        let profile = F.profile([
            F.snap(1, F.chrome, placement: .desktop(number: 2), z: 1),
            F.snap(2, F.slack, frame: slackFrame, minimized: true, z: 2),
            F.snap(3, F.notes, frame: Self.screenA, placement: .fullScreen(position: 2), fullScreen: true, z: 0),
            F.snap(4, F.safari, frame: safariFrame, z: 3),
        ])
        let scan = F.scan([
            F.live(101, F.chrome, frame: F.defaultFrame.offsetBy(dx: 300, dy: 0), spaces: [11]),
            F.live(102, F.slack, frame: slackFrame.offsetBy(dx: 0, dy: 90)),
            F.live(103, F.notes),
            F.live(104, F.safari, frame: Self.screenA, spaces: [13], fullScreen: true),
        ])
        let env = FakeRestoreEnvironment(scans: [scan])
        var events: [RestoreProgress] = []
        let report = await Self.engine(env).run(profile) { events.append($0) }

        #expect(env.actions == [
            "exitFullScreen:104",
            "moveToDesktop:101->12", "moveToDesktop:104->11",
            "setFrame:101", "setFrame:102", "setFrame:104",
            "enterFullScreen:103",
            "minimize:102",
        ])
        #expect(report.steps.count == 8)
        #expect(report.steps.allSatisfy { $0.status.isDone })
        #expect(report.steps.map(\.index) == Array(1...8))
        #expect(report.steps.map(\.phase) == report.steps.map(\.phase).sorted())
        #expect(report.totals.done == 8 && report.totals.failed == 0 && report.totals.skipped == 0)
        #expect(report.totals.windowsPlaced == 4)
        #expect(report.windows.count == 4)
        #expect(report.windows.allSatisfy { $0.outcome == .placed })
        #expect(report.summary == "4 windows placed")
        #expect(report.isClean)
        #expect(!report.dryRun && !report.cancelled)
        #expect(report.profileName == "Work")
        #expect(report.finishedAt >= report.startedAt)

        // The settle pass waited once and found nothing to correct.
        #expect(env.sleeps == [1])
        #expect(env.count("setFrame:101") == 1)

        // Progress: scanning first, planned, one start and one finish per step, settling, finished last.
        if case .scanning = events.first {} else { Issue.record("first event should be scanning") }
        if case .finished(let final) = events.last { #expect(final == report) } else { Issue.record("last event should be finished") }
        #expect(events.filter { if case .stepStarted = $0 { return true } else { return false } }.count == 8)
        #expect(events.filter { if case .stepFinished = $0 { return true } else { return false } }.count == 8)
        #expect(events.contains { if case .settling = $0 { return true } else { return false } })
        #expect(events.contains { if case .planned = $0 { return true } else { return false } })
    }

    @Test func nothingToDoGivesAnEmptyCleanReport() async {
        let profile = F.profile([F.snap(1, F.chrome)])
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome)])])
        let report = await Self.engine(env).run(profile)
        #expect(env.actions.isEmpty)
        #expect(env.sleeps.isEmpty)
        #expect(report.steps.isEmpty)
        #expect(report.windows.map(\.outcome) == [.placed])
        #expect(report.summary == "1 window placed")
        #expect(report.isClean)
    }

    // MARK: Launch

    @Test func launchesMissingAppsThenScansAndPlansAgain() async {
        let slackFrame = CGRect(x: 300, y: 200, width: 700, height: 500)
        let profile = F.profile([F.snap(1, F.slack, frame: slackFrame, z: 1), F.snap(2, F.chrome, z: 0)])
        let before = F.scan([F.live(102, F.chrome)])
        let after = F.scan([F.live(102, F.chrome), F.live(101, F.slack, frame: F.defaultFrame)])
        let env = FakeRestoreEnvironment(scans: [before, after])
        env.launchResults = [LaunchResult(app: F.slack, status: .launched, pid: 5, windowCount: 1,
                                          timings: LaunchResult.Timings(total: 0.5))]
        var plans = 0
        let report = await Self.engine(env).run(profile) { event in
            if case .planned = event { plans += 1 }
        }

        #expect(env.calls.filter { $0 == "scan" || $0.hasPrefix("launch") || $0.hasPrefix("setFrame") }
            == ["scan", "launch:Slack", "scan", "setFrame:101"])
        #expect(env.scanCount == 2)
        #expect(plans == 2)
        #expect(report.steps.first?.kind == "launch")
        #expect(report.steps.first?.status.isDone == true)
        #expect(report.launched.count == 1)
        #expect(report.launched[0].launched)
        #expect(report.launched[0].app == F.slack)
        #expect(report.totals.appsLaunched == 1)
        #expect(report.unmatched.isEmpty)
        #expect(report.windows.allSatisfy { $0.outcome == .placed })
        #expect(report.summary == "2 windows placed, 1 launched")
    }

    @Test func launchedAppWithoutAWindowStaysUnmatched() async {
        let profile = F.profile([F.snap(1, F.slack)])
        let env = FakeRestoreEnvironment(scans: [F.scan([])])
        let report = await Self.engine(env).run(profile)
        #expect(env.scanCount == 2)
        #expect(report.unmatched.count == 1)
        #expect(report.unmatched[0].reason.contains("opened fewer windows"))
        #expect(report.windows.map(\.outcome) == [.notFound])
        #expect(report.summary == "1 launched, 1 not found")
        #expect(!report.isClean)
    }

    @Test func appThatCannotBeFoundIsReportedAndTheRunGoesOn() async {
        let profile = F.profile([F.snap(1, F.slack), F.snap(2, F.chrome)])
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(102, F.chrome, frame: F.defaultFrame.offsetBy(dx: 90, dy: 0))])])
        env.launchResults = [LaunchResult(app: F.slack, status: .notFound)]
        let report = await Self.engine(env).run(profile)

        #expect(env.scanCount == 1) // nothing launched, so no second scan
        #expect(env.actions.contains("setFrame:102"))
        #expect(report.steps.first?.kind == "launch")
        #expect(report.steps.first?.status.isFailed == true)
        #expect(report.launched.first?.result == "not found")
        #expect(report.launched.first?.launched == false)
        #expect(report.unmatched.first?.reason.contains("could not be found") == true)
        #expect(report.totals.windowsNotFound == 1)
        #expect(report.summary == "1 window placed, 1 not found")
    }

    @Test func alreadyRunningAppIsSkippedNotFailed() async {
        let profile = F.profile([F.snap(1, F.slack)])
        let env = FakeRestoreEnvironment(scans: [F.scan([])])
        env.launchResults = [LaunchResult(app: F.slack, status: .alreadyRunning, pid: 9, windowCount: 0)]
        let report = await Self.engine(env).run(profile)
        #expect(report.steps.first?.status == .skipped("already running"))
        #expect(report.totals.appsLaunched == 0)
        #expect(env.scanCount == 1)
    }

    // MARK: Failures

    @Test func aFailingStepDoesNotStopTheRun() async {
        let profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.slack)])
        let moved = F.defaultFrame.offsetBy(dx: 400, dy: 0)
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome, frame: moved), F.live(102, F.slack, frame: moved)])])
        env.failures["setFrame:101"] = "the window refused the frame"
        let report = await Self.engine(env).run(profile)

        #expect(env.actions == ["setFrame:101", "setFrame:102"])
        #expect(report.steps[0].status == .failed("the window refused the frame"))
        #expect(report.steps[1].status.isDone)
        #expect(report.totals.failed == 1 && report.totals.done == 1)
        #expect(report.windows.map(\.outcome) == [.failed, .placed])
        #expect(report.windows[0].notes.contains { $0.contains("refused") })
        #expect(report.summary == "1 window placed, 1 failed")
        #expect(!report.isClean)
    }

    @Test func windowsWithoutAnAccessibilityElementFailTheirFrameStep() async {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2))])
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome, frame: F.defaultFrame.offsetBy(dx: 200, dy: 0), spaces: [11])])])
        env.unreachable = [101]
        let report = await Self.engine(env).run(profile)

        // The Desktop move needs no element; the frame does.
        #expect(env.actions == ["moveToDesktop:101->12"])
        #expect(report.steps.map(\.kind) == ["moveToDesktop", "setFrame"])
        #expect(report.steps[0].status.isDone)
        #expect(report.steps[1].status == .failed("window not reachable by Accessibility"))
        #expect(report.windows.map(\.outcome) == [.partial])
        #expect(env.sleeps.isEmpty) // nothing was placed, nothing to settle
    }

    @Test func aMissingDesktopIsReportedInThePlanWarnings() async {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 5))])
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome)])])
        let report = await Self.engine(env).run(profile)
        #expect(env.actions.isEmpty)
        #expect(report.warnings.contains { $0.contains("missing Desktop 5") })
    }

    @Test func aStepThatTakesTooLongTimesOutAndTheRunGoesOn() async {
        let profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.slack)])
        let moved = F.defaultFrame.offsetBy(dx: 400, dy: 0)
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome, frame: moved), F.live(102, F.slack, frame: moved)])])
        env.delays["setFrame:101"] = 5
        let started = ProcessInfo.processInfo.systemUptime
        let report = await Self.engine(env, stepTimeout: 0.05).run(profile)
        let took = ProcessInfo.processInfo.systemUptime - started

        #expect(took < 2)
        #expect(env.actions == ["setFrame:101", "setFrame:102"])
        #expect(report.steps[0].status.isFailed)
        #expect(report.steps[0].status.reason?.contains("timed out") == true)
        #expect(report.steps[1].status.isDone)
    }

    // MARK: Cancellation

    @Test func cancellationStopsBetweenStepsAndReportsWhatWasDone() async {
        let apps = [F.chrome, F.slack, F.notes, F.safari]
        let moved = F.defaultFrame.offsetBy(dx: 400, dy: 0)
        let profile = F.profile(apps.enumerated().map { F.snap($0.offset + 1, $0.element) })
        let scan = F.scan(apps.enumerated().map { F.live(UInt32(101 + $0.offset), $0.element, frame: moved) })
        let env = FakeRestoreEnvironment(scans: [scan])
        let engine = Self.engine(env)

        let box = TaskBox()
        let task = Task { @MainActor in
            await engine.run(profile) { event in
                if case .stepFinished(let index, _, _, _, _) = event, index == 1 { box.task?.cancel() }
            }
        }
        box.task = task
        let report = await task.value

        #expect(env.actions == ["setFrame:101"])
        #expect(report.cancelled)
        #expect(report.steps.count == 4)
        #expect(report.steps[0].status.isDone)
        #expect(report.steps.dropFirst().allSatisfy { $0.status == .skipped("cancelled") })
        #expect(env.sleeps.isEmpty) // no settle pass after a cancel
        #expect(report.windows.map(\.outcome) == [.placed, .notDone, .notDone, .notDone])
        #expect(report.summary.hasPrefix("Cancelled:"))
        #expect(!report.isClean)
    }

    @Test func cancellingBeforeTheRunStartsDoesNothingToTheWorkspace() async {
        let profile = F.profile([F.snap(1, F.slack), F.snap(2, F.chrome)])
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(102, F.chrome, frame: F.defaultFrame.offsetBy(dx: 400, dy: 0))])])
        let engine = Self.engine(env)
        let task = Task { @MainActor in
            await engine.run(profile)
        }
        task.cancel()
        let report = await task.value
        #expect(env.actions.isEmpty)
        #expect(report.cancelled)
        #expect(report.steps.allSatisfy { $0.status == .skipped("cancelled") })
    }

    // MARK: Settle

    @Test func settleSetsTheFrameAgainWhenAWindowDrifted() async {
        let profile = F.profile([F.snap(1, F.chrome), F.snap(2, F.slack)])
        let moved = F.defaultFrame.offsetBy(dx: 400, dy: 0)
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome, frame: moved), F.live(102, F.slack, frame: moved)])])
        // Chrome (an Electron-like app) resized itself after it was placed; Slack stayed.
        env.frameReadings[101] = [CGRect(x: 100, y: 100, width: 640, height: 480)]
        let report = await Self.engine(env).run(profile)

        #expect(env.sleeps == [1])
        #expect(env.count("setFrame:101") == 2)
        #expect(env.count("setFrame:102") == 1)
        let again = report.steps.last
        #expect(again?.kind == "reapplyFrame")
        #expect(again?.status.isDone == true)
        #expect(again?.windowID == 101)
        #expect(again?.description.contains("drifted") == true)
        #expect(report.totals.driftCorrections == 1)
        #expect(report.windows.allSatisfy { $0.outcome == .placed })
    }

    @Test func settleDoesNotCheckMinimizedOrFullScreenWindows() async {
        let profile = F.profile([
            F.snap(1, F.chrome, minimized: true),
            F.snap(2, F.notes, frame: Self.screenA, placement: .fullScreen(position: 2), fullScreen: true),
        ])
        let moved = F.defaultFrame.offsetBy(dx: 400, dy: 0)
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome, frame: moved), F.live(102, F.notes, frame: moved)])])
        env.frameReadings[101] = [.zero]
        let report = await Self.engine(env).run(profile)
        #expect(env.actions == ["setFrame:101", "enterFullScreen:102", "minimize:101"])
        #expect(env.sleeps.isEmpty)
        #expect(report.totals.driftCorrections == 0)
    }

    @Test func aWindowThatStaysLargerThanAskedIsNotChasedBySettle() async {
        // A minimum size makes the window larger than the frame; the size it ends up with is the one to keep.
        let profile = F.profile([F.snap(1, F.chrome)])
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome, frame: F.defaultFrame.offsetBy(dx: 400, dy: 0))])])
        env.biggerFrame = CGRect(x: 100, y: 100, width: 900, height: 700)
        let report = await Self.engine(env).run(profile)
        #expect(env.count("setFrame:101") == 1)
        #expect(env.sleeps == [1])
        #expect(report.totals.driftCorrections == 0)
    }

    // MARK: Dry run

    @Test func dryRunScansAndPlansButChangesNothing() async {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2)), F.snap(2, F.slack)],
                                options: ProfileOptions(otherApps: .hide))
        let scan = F.scan([F.live(101, F.chrome, spaces: [11]), F.live(103, F.safari, pid: 2001)])
        let env = FakeRestoreEnvironment(scans: [scan])
        var events: [RestoreProgress] = []
        let report = await Self.engine(env).run(profile, dryRun: true) { events.append($0) }

        #expect(env.calls == ["scan"])
        #expect(report.dryRun)
        #expect(report.steps.map(\.kind) == ["launch", "moveToDesktop", "hideApp"])
        #expect(report.steps.allSatisfy { $0.status == .skipped("dry run") })
        #expect(report.windows.map(\.outcome) == [.planned, .notFound])
        #expect(report.unmatched.count == 1)
        #expect(report.summary.hasPrefix("Dry run: 1 window to change"))
        #expect(report.summary.contains("1 app to launch"))
        #expect(report.summary.contains("1 app to hide"))
        #expect(report.summary.contains("1 not found"))
        #expect(!events.contains { if case .stepStarted = $0 { return true } else { return false } })
        #expect(report.launched.isEmpty)
    }

    // MARK: Other apps

    @Test func hidesOtherAppsButNeverQuitsThem() async {
        let scan = F.scan([F.live(101, F.chrome), F.live(102, F.safari, pid: 2001), F.live(103, F.finder, pid: 2002)])

        let hideEnv = FakeRestoreEnvironment(scans: [scan])
        let hide = await Self.engine(hideEnv).run(F.profile([F.snap(1, F.chrome)], options: ProfileOptions(otherApps: .hide)))
        #expect(hideEnv.actions == ["hide:2001", "hide:2002"])
        #expect(hide.totals.appsHidden == 2)
        #expect(hide.summary == "1 window placed, 2 hidden")

        let quitEnv = FakeRestoreEnvironment(scans: [scan])
        let quit = await Self.engine(quitEnv).run(F.profile([F.snap(1, F.chrome)], options: ProfileOptions(otherApps: .quit)))
        #expect(quitEnv.actions.isEmpty)
        #expect(quit.needsConfirmation == [F.safari, F.finder])
        #expect(quit.steps.allSatisfy { $0.status == .skipped("needs confirmation") })
        #expect(quit.totals.appsNeedingConfirmation == 2)
        #expect(quit.summary.contains("2 apps to quit need confirmation"))
    }

    // MARK: Full screen

    @Test func fullScreenWindowsAreEnteredOneAtATimeInSavedOrder() async {
        let profile = F.profile([
            F.snap(1, F.slack, display: F.uuidB, frame: Self.screenB, placement: .fullScreen(position: 1), fullScreen: true),
            F.snap(2, F.chrome, frame: Self.screenA, placement: .fullScreen(position: 3), fullScreen: true),
            F.snap(3, F.notes, frame: Self.screenA, placement: .fullScreen(position: 2), fullScreen: true),
        ])
        let slack = F.live(101, F.slack, display: F.uuidB, frame: CGRect(x: 2000, y: 50, width: 800, height: 600), spaces: [21])
        let env = FakeRestoreEnvironment(scans: [F.scan([slack, F.live(102, F.chrome), F.live(103, F.notes)])])
        for id in [101, 102, 103] { env.delays["enterFullScreen:\(id)"] = 0.01 }
        let report = await Self.engine(env).run(profile)

        #expect(env.actions == ["enterFullScreen:103", "enterFullScreen:102", "enterFullScreen:101"])
        #expect(env.maxActive == 1)
        #expect(report.windows.allSatisfy { $0.outcome == .placed })
    }

    @Test func aWindowOnTheWrongMonitorIsMovedThereBeforeItEntersFullScreen() async {
        let profile = F.profile([
            F.snap(1, F.chrome, display: F.uuidB, frame: Self.screenB, placement: .fullScreen(position: 1), fullScreen: true),
        ])
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome)])])
        let report = await Self.engine(env).run(profile)
        #expect(env.actions == ["setFrame:101", "enterFullScreen:101"])
        #expect(report.windows.map(\.outcome) == [.placed])
        #expect(env.sleeps.isEmpty) // the move before full screen is not checked by the settle pass
    }

    // MARK: Report

    @Test func reportSurvivesAJSONRoundTrip() async throws {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2)), F.snap(2, F.slack)],
                                options: ProfileOptions(otherApps: .quit))
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome, spaces: [11]), F.live(103, F.safari, pid: 2001)])])
        env.failures["moveToDesktop:101->12"] = "no way to move windows"
        var report = await Self.engine(env).run(profile)
        // ISO 8601 keeps whole seconds only.
        report.startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        report.finishedAt = Date(timeIntervalSince1970: 1_800_000_007)

        let data = try report.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"status\" : \"failed\""))
        #expect(text.contains("\"reason\" : \"no way to move windows\""))
        #expect(text.contains("\"status\" : \"skipped\""))
        let back = try RestoreReport.decode(data)
        #expect(back == report)
        #expect(back.steps.contains { $0.status == .failed("no way to move windows") })
    }

    @Test func progressMessagesAreReadable() async {
        let profile = F.profile([F.snap(1, F.chrome)])
        let env = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome, frame: F.defaultFrame.offsetBy(dx: 400, dy: 0))])])
        var lines: [String] = []
        _ = await Self.engine(env).run(profile) { lines.append($0.message) }
        #expect(lines.first == "Scanning monitors, Spaces and windows")
        #expect(lines.contains { $0.hasPrefix("Plan: 1 step") })
        #expect(lines.contains { $0.hasPrefix("[1/1] set frame") && $0.contains("-> done") })
        #expect(lines.last == "1 window placed")
    }

    @Test func statusAndOutcomeHelpers() {
        #expect(RestoreStepStatus.done.text == "done")
        #expect(RestoreStepStatus.skipped("dry run").text == "skipped: dry run")
        #expect(RestoreStepStatus.failed("boom").reason == "boom")
        #expect(RestoreStepStatus.done.reason == nil)
        #expect(RestoreStepStatus.done.isDone && RestoreStepStatus.failed("x").isFailed && RestoreStepStatus.skipped("x").isSkipped)
    }
}
