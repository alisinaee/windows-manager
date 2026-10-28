import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Scenario flow: scramble -> restore -> verify. The verdict comes from DebugVerify; scrambling is in
// DebugScramble.swift.

/// Collects events, forwards them and appends each one to the log file.
final class DebugSink: @unchecked Sendable {
    private let onEvent: @Sendable (DebugEvent) -> Void
    private let lock = NSLock()
    private(set) var checks: [DebugCheck] = []
    private(set) var lines: [String] = []
    /// Window ids a scenario created on purpose as "extras" (S4).
    var markedExtras: Set<UInt32> = []

    init(onEvent: @escaping @Sendable (DebugEvent) -> Void) { self.onEvent = onEvent }

    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Windows Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug-tests.log")
    }()

    func send(_ event: DebugEvent) {
        let line: String
        switch event {
        case .phase(let p): line = "PHASE \(p)"
        case .step(let s): line = "STEP \(s.id) \(s.kind) \(s.target) \(s.status.rawValue) \(s.detail)"
        case .check(let c): line = "CHECK \(c.passed ? "PASS" : "FAIL") \(c.name) \(c.detail)"
        case .log(let l): line = "LOG \(l)"
        }
        lock.lock()
        if case .check(let c) = event { checks.append(c) }
        lines.append(line)
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let data = stamped.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: Self.logURL) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: Self.logURL)
            }
        }
        lock.unlock()
        onEvent(event)
    }
}

extension DebugTestRunner {
    public func run(_ s: DebugScenarioID, onEvent: @escaping @Sendable (DebugEvent) -> Void) async -> DebugRunResult {
        let sink = DebugSink(onEvent: onEvent)
        sink.send(.phase("Start \(s.title)"))
        func check(_ id: String, _ name: String, _ ok: Bool, _ detail: String) {
            sink.send(.check(DebugCheck(id: id, name: name, passed: ok, detail: detail)))
        }
        do {
            sink.send(.phase("Installing fixture profiles"))
            let profiles = try Self.installFixtureProfiles(into: store)
            let name = s == .home ? "Home" : "Challenge Work"
            if AXIsProcessTrusted(), let profile = profiles.first(where: { $0.name == name }) {
                sink.send(.phase("Scramble"))
                await scramble(s, profile: profile, sink: sink)
                let extras = await captureExtras(sink: sink)
                sink.send(.phase("Restore"))
                let report = await runEngine(profile, sink: sink)
                sink.send(.log("report: \(report.summary)"))
                let failed = report.steps.filter { $0.status.isFailed }
                // Adding a Desktop drives Mission Control; when this macOS blocks that, it is a system limit.
                let desktopLimit = failed.filter { $0.description.hasPrefix("add ") && $0.description.contains("Desktop") }
                let realFailed = failed.filter { f in !desktopLimit.contains { $0.description == f.description } }
                check("report-steps", "every report step done or skipped", realFailed.isEmpty,
                      realFailed.isEmpty ? "\(report.steps.count) steps" + (desktopLimit.isEmpty ? ""
                          : "; INCONCLUSIVE: could not add a Desktop (\(desktopLimit.count) step), Mission Control not drivable here")
                          : realFailed.map(\.description).joined(separator: "; "))
                sink.send(.phase("Verify"))
                await verify(profile, extras: extras, sink: sink)
                if s == .s7Rerun {
                    sink.send(.phase("Restore again"))
                    let second = await runEngine(profile, sink: sink)
                    let moves = second.steps.filter { $0.status.isDone }
                    let launches = second.launched.filter(\.launched)
                    check("rerun-moves", "second run: 0 moves", moves.isEmpty,
                          moves.isEmpty ? "0 steps done" : moves.map(\.description).joined(separator: "; "))
                    check("rerun-launch", "second run: 0 launches", launches.isEmpty, "\(launches.count) launched")
                }
            } else {
                check("setup", "setup", false, AXIsProcessTrusted() ? "\(name) missing" : "Accessibility not trusted")
            }
        } catch {
            check("error", "runner error", false, "\(error)")
        }
        let passed = !sink.checks.isEmpty && sink.checks.allSatisfy(\.passed)
        sink.send(.phase(passed ? "PASSED" : "FAILED"))
        return DebugRunResult(scenario: s, passed: passed, checks: sink.checks, log: sink.lines)
    }

    // MARK: Restore

    @MainActor
    private func runEngine(_ profile: Profile, sink: DebugSink) async -> RestoreReport {
        let engine = RestoreEngine()
        engine.configuration.addMissingDesktops = true
        return await engine.run(profile, dryRun: false) { p in
            switch p {
            case .planned(let plan):
                sink.send(.log(p.message))
                for (i, step) in plan.steps.enumerated() {
                    sink.send(.step(DebugStepRow(id: "step-\(i + 1)", kind: step.kind, target: step.description,
                                                 status: .pending, detail: "")))
                }
            case .stepStarted(let i, _, let d):
                sink.send(.step(DebugStepRow(id: "step-\(i)", kind: "", target: d, status: .running, detail: "")))
            case .stepFinished(let i, _, let d, let status, let elapsed):
                var st = DebugStepStatus.done
                var detail = String(format: "%.2f s", elapsed)
                switch status {
                case .done: break
                case .skipped(let r): st = .skipped; detail = r
                case .failed(let r): st = .failed; detail = r
                }
                sink.send(.step(DebugStepRow(id: "step-\(i)", kind: "", target: d, status: st, detail: detail)))
            default:
                sink.send(.log(p.message))
            }
        }
    }

    // MARK: Verify

    func liveWindows() async -> [DebugLiveWindow] {
        let scan = await Task.detached { WorkspaceScanner.scan() }.value
        return Self.convert(scan)
    }

    func stageManagerOn() async -> Bool {
        await Task.detached { WorkspaceScanner.scan().stageManagerOn == true }.value
    }

    func desktopCount() async -> Int {
        let scan = await Task.detached { WorkspaceScanner.scan() }.value
        let main = DisplayMap.current().first(where: \.isMain)?.uuid
        let list = scan.spaces.first { $0.displayUUID == main } ?? scan.spaces.first
        return list?.spaces.filter { $0.kind == .desktop }.count ?? 0
    }

    static func convert(_ scan: WorkspaceScan) -> [DebugLiveWindow] {
        var desktopOf: [UInt64: Int] = [:]
        for list in scan.spaces {
            var n = 0
            for sp in list.spaces.sorted(by: { $0.index < $1.index }) where sp.kind == .desktop {
                n += 1
                desktopOf[sp.id] = n
            }
        }
        return scan.windows.filter { !$0.isStripThumbnail }.map { w in
            DebugLiveWindow(windowID: w.windowID, bundleID: w.app.bundleID, title: w.title, frame: w.frame,
                            desktop: w.spaceIDs.count == 1 ? desktopOf[w.spaceIDs[0]] : nil,
                            isMinimized: w.isMinimized, isFullScreen: w.isFullScreen, isAppHidden: w.isAppHidden,
                            isInStageStrip: w.isInStageStrip)
        }
    }

    static func expectations(for profile: Profile) -> [DebugExpectation] {
        profile.windows.filter(\.restore).map { w in
            var desktop: Int?
            if case .desktop(let n) = w.placement { desktop = n }
            return DebugExpectation(label: "\(w.app.name)#\(w.indexInApp)", bundleID: w.app.bundleID ?? "", frame: w.frame,
                                    desktop: desktop, isMinimized: w.isMinimized, isFullScreen: w.isFullScreen)
        }
    }

    /// Polls up to 5 s, then emits the checks of the last evaluation.
    private func verify(_ profile: Profile, extras: [DebugExtra], sink: DebugSink) async {
        let wanted = Self.expectations(for: profile)
        var checks: [DebugCheck] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let live = await liveWindows()
            let count = await desktopCount()
            let sm = await stageManagerOn()
            checks = DebugVerify.evaluate(expectations: wanted, live: live, extras: extras, desktopCount: count, stageManagerOn: sm)
            if checks.allSatisfy(\.passed) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < deadline
        do {
            let smOn = await stageManagerOn()
            sink.send(.log("verify: stageManagerOn=\(smOn)"))
            for w in await liveWindows() where w.bundleID.map(Self.fixtureBundles.contains) ?? false {
                sink.send(.log("live: \(w.bundleID ?? "?") id \(w.windowID) \"\(w.title ?? "")\" \(DebugVerify.describe(w.frame)) d\(w.desktop.map(String.init) ?? "?") min=\(w.isMinimized) hidden=\(w.isAppHidden) strip=\(w.isInStageStrip)"))
            }
        }
        for c in checks { sink.send(.check(c)) }
    }

    /// Windows of apps outside the fixture set (on a known desktop), plus the S4 extra, must not change.
    private func captureExtras(sink: DebugSink) async -> [DebugExtra] {
        let marked = sink.markedExtras
        return await liveWindows().filter { w in
            marked.contains(w.windowID)
                || (w.desktop != nil && !(w.bundleID.map(Self.fixtureBundles.contains) ?? true))
        }.map { DebugExtra(windowID: $0.windowID, label: $0.title ?? "\($0.windowID)", frame: $0.frame, desktop: $0.desktop) }
    }
}
