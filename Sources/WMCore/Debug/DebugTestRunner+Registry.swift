import ApplicationServices
import CoreGraphics
import Foundation

// Registry-driven run (P6.126): legacy scenarios go through `run(_:)`, power-user scenarios through the flow below
// (preconditions -> scramble -> restore -> verify rules -> optional second run).

extension DebugTestRunner {
    public func run(_ entry: DebugRunnerEntry, onEvent: @escaping @Sendable (DebugEvent) -> Void) async -> DebugRunResult {
        if let legacy = entry.legacy { return await run(legacy, onEvent: onEvent) }
        return await runPowerUser(entry, onEvent: onEvent)
    }

    private func runPowerUser(_ entry: DebugRunnerEntry, onEvent: @escaping @Sendable (DebugEvent) -> Void) async -> DebugRunResult {
        let sink = DebugSink(onEvent: onEvent)
        sink.send(.phase("Start \(entry.title)"))
        func finish(_ status: DebugRunStatus) -> DebugRunResult {
            sink.send(.phase(status.rawValue))
            return DebugRunResult(scenarioID: entry.id, title: entry.title, status: status, checks: sink.checks, log: sink.lines)
        }
        func note(_ id: String, _ status: DebugRunStatus, _ detail: String) -> DebugRunResult {
            sink.send(.check(DebugCheck(id: id, name: "preconditions", passed: status != .fail, detail: "\(status.rawValue): \(detail)")))
            return finish(status)
        }
        let installed = DebugFixtures.availableBundleIDs()
        let missing = entry.requiredBundleIDs.filter { !installed.contains($0) }
        if !missing.isEmpty { return note("skipped", .skipped, "missing app(s) \(missing.joined(separator: ", "))") }
        guard AXIsProcessTrusted() else { return note("permission", .inconclusive, "Accessibility not trusted") }
        let displays = DisplayMap.current().count
        if displays < entry.requiredDisplays {
            return note("displays", .inconclusive, "needs \(entry.requiredDisplays) display(s), found \(displays)")
        }
        if await stageManagerOn() { return note("stage-manager", .inconclusive, "Stage Manager is on") }

        do {
            sink.send(.phase("Installing fixture profiles"))
            let profiles = try DebugFixtures.installPowerUserFixtures(into: store)
            guard let profile = profiles.first(where: { $0.name == entry.fixtureProfile }) else {
                sink.send(.check(DebugCheck(id: "setup", name: "setup", passed: false, detail: "\(entry.fixtureProfile) missing")))
                return finish(.fail)
            }
            sink.send(.phase("Scramble"))
            await scramblePowerUser(profile: profile, sink: sink)
            sink.send(.phase("Restore"))
            let report = await runEngine(profile, sink: sink)
            sink.send(.log("report: \(report.summary)"))
            let failed = report.steps.filter { $0.status.isFailed }
            sink.send(.check(DebugCheck(id: "report-steps", name: "every report step done or skipped", passed: failed.isEmpty,
                                        detail: failed.isEmpty ? "\(report.steps.count) steps" : failed.map(\.description).joined(separator: "; "))))
            sink.send(.phase("Verify"))
            let wanted = Self.expectations(for: profile)
            let limited = Set(entry.expectsSizeLimited)
            var live = await liveWindows()
            var checks = DebugVerify.evaluate(expectations: wanted, live: live, desktopCount: await desktopCount())
            if entry.verifyRules.contains("size-limited") {
                // A limited window may refuse the size: judged by the size-limited rule on the second run instead.
                let skip = Set(wanted.enumerated().filter { limited.contains($0.element.bundleID) }.map { "w\($0.offset)-" })
                checks.removeAll { c in skip.contains { c.id.hasPrefix($0) && c.id.hasSuffix("-frame") } }
            }
            if entry.verifyRules.contains("duplicate-ids") { checks += DebugVerify.duplicateIDChecks(live: live) }
            for c in checks { sink.send(.check(c)) }

            if entry.verifyRules.contains("idempotence") || entry.verifyRules.contains("size-limited") {
                let fixtureLive = live.filter { w in wanted.contains { $0.bundleID == w.bundleID } }
                let first = Dictionary(fixtureLive.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { a, _ in a })
                sink.send(.phase("Restore again"))
                let second = await runEngine(profile, sink: sink)
                let moves = second.steps.filter { $0.status.isDone }
                sink.send(.check(DebugCheck(id: "rerun-moves", name: "second run: 0 moves", passed: moves.isEmpty,
                                            detail: moves.isEmpty ? "0 steps done" : moves.map(\.description).joined(separator: "; "))))
                live = await liveWindows()
                let fixtureLive2 = live.filter { w in wanted.contains { $0.bundleID == w.bundleID } }
                if entry.verifyRules.contains("idempotence") {
                    let again = Dictionary(fixtureLive2.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { a, _ in a })
                    for c in DebugVerify.idempotenceChecks(first: first, second: again) { sink.send(.check(c)) }
                }
                if entry.verifyRules.contains("size-limited") {
                    for (i, e) in wanted.enumerated() where limited.contains(e.bundleID) {
                        let w1 = fixtureLive.first { $0.bundleID == e.bundleID }
                        let w2 = fixtureLive2.first { $0.windowID == w1?.windowID }
                        sink.send(.check(DebugVerify.sizeLimitedCheck(id: "size-limited-\(i)", label: e.label, wanted: e.frame,
                                                                     actual: w2?.frame, learnedLimit: w1?.frame.size)))
                    }
                }
            }
        } catch {
            sink.send(.check(DebugCheck(id: "error", name: "runner error", passed: false, detail: "\(error)")))
        }
        let inconclusive = sink.checks.allSatisfy(\.passed) && sink.checks.contains { $0.detail.hasPrefix("INCONCLUSIVE") && $0.id.hasPrefix("size-limited") }
        let status: DebugRunStatus = sink.checks.isEmpty || !sink.checks.allSatisfy(\.passed) ? .fail : (inconclusive ? .inconclusive : .pass)
        return finish(status)
    }
}
