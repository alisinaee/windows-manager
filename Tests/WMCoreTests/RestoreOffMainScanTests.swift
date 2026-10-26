import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Wraps the fake environment and blocks like the live one would (AX calls), but off the main actor, through the
/// same helper the live environment uses.
@MainActor
private final class BlockingRestoreEnvironment: RestoreEnvironment {
    let inner: FakeRestoreEnvironment
    var scanBlock: TimeInterval = 0
    var elementBlock: TimeInterval = 0

    init(_ inner: FakeRestoreEnvironment) { self.inner = inner }

    func scan() async -> WorkspaceScan {
        let block = scanBlock
        await LiveRestoreEnvironment.runOffMain { Thread.sleep(forTimeInterval: block) }
        return await inner.scan()
    }

    func launchAll(_ requests: [LaunchRequest]) async -> [LaunchResult] { await inner.launchAll(requests) }

    func element(for target: RestoreTarget) async -> WindowHandle? {
        let block = elementBlock
        await LiveRestoreEnvironment.runOffMain { Thread.sleep(forTimeInterval: block) }
        return await inner.element(for: target)
    }

    func setFrame(_ handle: WindowHandle, to frame: CGRect) async -> RestoreActionResult { await inner.setFrame(handle, to: frame) }
    func setFullScreen(_ handle: WindowHandle, _ on: Bool, timeout: TimeInterval) async -> RestoreActionResult {
        await inner.setFullScreen(handle, on, timeout: timeout)
    }
    func minimize(_ handle: WindowHandle) async -> RestoreActionResult { await inner.minimize(handle) }
    func unminimize(_ handle: WindowHandle) async -> RestoreActionResult { await inner.unminimize(handle) }
    func raise(_ handle: WindowHandle, app: AppRef) async -> RestoreActionResult { await inner.raise(handle, app: app) }
    func moveToDesktop(windowID: UInt32, spaceID: UInt64) async -> RestoreActionResult {
        await inner.moveToDesktop(windowID: windowID, spaceID: spaceID)
    }
    func hideApp(pid: Int32, app: AppRef) async -> RestoreActionResult { await inner.hideApp(pid: pid, app: app) }
    func frameOf(_ handle: WindowHandle) async -> CGRect? { await inner.frameOf(handle) }
    func sleep(_ seconds: TimeInterval) async { await inner.sleep(seconds) }
}

@MainActor
@Suite struct RestoreOffMainScanTests {
    typealias F = RestoreFixtures

    /// Counts how often the main actor gets to run while `work` is in flight.
    private func ticksWhile(_ work: () async -> Void) async -> Int {
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
                ticks += 1
            }
        }
        await work()
        ticker.cancel()
        return ticks
    }

    @Test func slowScanDoesNotBlockTheMainActor() async {
        let profile = F.profile([F.snap(1, F.chrome)])
        let moved = F.defaultFrame.offsetBy(dx: 300, dy: 0)
        let fake = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome, frame: moved)])])
        let env = BlockingRestoreEnvironment(fake)
        env.scanBlock = 0.5
        let engine = RestoreEngine(environment: env)
        var report: RestoreReport?
        let ticks = await ticksWhile { report = await engine.run(profile) }
        #expect(ticks >= 10) // ~25 ticks fit into 0.5 s; a blocked main actor gives 0 or 1
        #expect(report?.steps.first?.status.isDone == true)
    }

    @Test func slowElementLookupTimesOutAndLeavesTheMainActorFree() async {
        let profile = F.profile([F.snap(1, F.chrome)])
        let moved = F.defaultFrame.offsetBy(dx: 300, dy: 0)
        let fake = FakeRestoreEnvironment(scans: [F.scan([F.live(101, F.chrome, frame: moved)])])
        let env = BlockingRestoreEnvironment(fake)
        env.elementBlock = 1.0
        var configuration = RestoreEngine.Configuration()
        configuration.stepTimeout = 0.1
        let engine = RestoreEngine(environment: env, configuration: configuration)
        var report: RestoreReport?
        let started = ProcessInfo.processInfo.systemUptime
        let ticks = await ticksWhile { report = await engine.run(profile) }
        let took = ProcessInfo.processInfo.systemUptime - started
        #expect(took < 0.9) // the timeout fired while the lookup was still blocked
        #expect(ticks >= 2)
        #expect(report?.steps.first?.status.isFailed == true)
        #expect(report?.steps.first?.status.reason?.contains("timed out") == true)
    }
}
