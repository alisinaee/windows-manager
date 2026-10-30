import Foundation
import Testing
@testable import WMCore

/// Thread-safe event log for work that runs on a background queue.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func add(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(event)
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// A Desktop mover that is slow the way the real SpaceMover is: a blocking call run off the main thread, which
/// keeps running after the engine has stopped waiting for it.
@MainActor
final class SlowSpaceMover: SpaceMoving {
    let seconds: TimeInterval
    private(set) var finished: [UInt32] = []

    init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    func move(windowID: UInt32, toSpace spaceID: UInt64) async -> RestoreActionResult {
        let seconds = self.seconds
        await SpaceMover.runOffCaller { Thread.sleep(forTimeInterval: seconds) }
        finished.append(windowID)
        return .ok("moved slowly")
    }
}

@MainActor
@Suite struct RestoreMoveOffMainTests {
    typealias F = RestoreFixtures

    @Test func blockingWorkDoesNotHoldTheMainActor() async {
        // The work blocks until the test releases it, so no wall-clock margin is involved: the only ordering
        // that matters is "main actor resumes while the work is still blocked".
        let gate = DispatchSemaphore(value: 0)
        let log = EventLog()
        let blocking = Task { await SpaceMover.runOffCaller { () -> Int in
            log.add("work start")
            // Bounded so a regression that blocks the main actor fails the test instead of hanging the run.
            _ = gate.wait(timeout: .now() + 10)
            log.add("work end")
            return 7
        } }
        // Wait (bounded poll, no fixed sleep) until the work has actually started.
        for _ in 0..<1000 where log.events.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        // If the work ran on the main thread, this sleep could not return while the work is still blocked.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(log.events == ["work start"])
        gate.signal()
        #expect(await blocking.value == 7)
        #expect(log.events == ["work start", "work end"])
    }

    @Test func blockingWorkRunsOneItemAtATime() async {
        let log = EventLog()
        async let first: Void = SpaceMover.runOffCaller {
            log.add("first start")
            Thread.sleep(forTimeInterval: 0.2)
            log.add("first end")
        }
        async let second: Void = SpaceMover.runOffCaller {
            log.add("second start")
            log.add("second end")
        }
        _ = await (first, second)

        let events = log.events
        #expect(events.count == 4)
        // Whichever ran first, its end comes right after its start: the two never overlap.
        if events.count == 4 {
            #expect(events[0].hasSuffix("start"))
            #expect(events[1] == events[0].replacingOccurrences(of: "start", with: "end"))
            #expect(events[2].hasSuffix("start"))
            #expect(events[3] == events[2].replacingOccurrences(of: "start", with: "end"))
        }
    }

    @Test func slowMoveTimesOutWithoutBlockingTheEngine() async {
        let profile = F.profile([F.snap(1, F.chrome, placement: .desktop(number: 2)), F.snap(2, F.slack)])
        let moved = F.defaultFrame.offsetBy(dx: 400, dy: 0)
        let env = FakeRestoreEnvironment(scans: [F.scan([
            F.live(101, F.chrome, frame: moved, spaces: [11]),
            F.live(102, F.slack, frame: moved),
        ])])
        // The mover needs 3 s; the move gives up after 0.2 s. Other steps get a generous budget so a loaded runner
        // cannot make them time out and mask the behaviour under test.
        let mover = SlowSpaceMover(seconds: 3.0)
        env.mover = mover
        var configuration = RestoreEngine.Configuration()
        configuration.stepTimeout = 1.0
        configuration.moveTimeout = 0.2
        let engine = RestoreEngine(environment: env, configuration: configuration)

        let started = ProcessInfo.processInfo.systemUptime
        let report = await engine.run(profile)
        let took = ProcessInfo.processInfo.systemUptime - started

        // The run returned well before the mover's own 3 s, and the abandoned move had not finished yet.
        #expect(took < mover.seconds)
        #expect(mover.finished.isEmpty)
        #expect(report.steps[0].kind == "moveToDesktop")
        #expect(report.steps[0].status.isFailed)
        #expect(report.steps[0].status.reason?.contains("timed out") == true)
        // The later steps still ran and succeeded.
        #expect(report.steps.dropFirst().allSatisfy { $0.status.isDone })
        #expect(env.actions.contains("setFrame:102"))

        // The abandoned move finishes on its own later. It can queue behind other tests' blocking work on the
        // shared queue, so poll with a generous bound instead of sleeping a fixed time.
        for _ in 0..<1000 where mover.finished.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(mover.finished == [101])
    }
}
