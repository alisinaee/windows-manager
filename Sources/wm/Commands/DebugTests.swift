import Foundation
import WMCore

private let debugResultsURL = DebugRunReport.resultURL

/// Result of one `wm debug run`: the scenario results, or the error that stopped the run before any scenario.
private struct DebugRunOutcome: Sendable {
    var results: [DebugRunResult]
    var error: String?
}

func registerDebugTestsCommands(_ r: Registry) {
    r.register(Command(["debug", "list"], summary: "List the live debug scenarios (id, title, summary)") { _, _ in
        let scenarios = DebugScenarioID.allCases
        let data = JSONValue.object(["scenarios": .array(scenarios.map {
            JSONValue.object(["id": .string($0.rawValue), "title": .string($0.title), "summary": .string($0.summary)])
        })])
        return CLIResult(data: data, text: scenarios.map { "\($0.rawValue)\t\($0.title) - \($0.summary)" }.joined(separator: "\n"))
    })

    r.register(Command(["debug", "results"], summary: "Show the last headless debug run (debug-run.json)") { _, _ in
        guard FileManager.default.fileExists(atPath: debugResultsURL.path) else {
            throw CLIFailure.notFound("No debug run results yet.",
                                      hint: "A run writes debug-run.json when the app is started with --debug-run.")
        }
        let data = try Data(contentsOf: debugResultsURL)
        let root = try cliService { try JSONDecoder().decode(JSONValue.self, from: data) }
        return CLIResult(data: root)
    })

    r.register(Command(["debug", "run"],
                       summary: "Run live debug scenarios on this desktop (moves real windows; needs --yes)",
                       options: [CLIOption("scenario", "Scenario id, or all (default)", takesValue: true, valueName: "id"),
                                 CLIOption("yes", short: "y", "Required: confirm that real windows will move")],
                       mutates: true, touchesWindows: true) { args, ctx in
        guard args.flag("yes") else {
            throw CLIFailure.usage("wm debug run moves real windows on this desktop, so it needs --yes",
                                   hint: "Scenarios: wm debug list. Run one with: wm debug run --scenario <id> --yes")
        }
        let value = args.value("scenario") ?? "all"
        guard let scenarios = DebugRunReport.scenarios(for: value) else {
            throw CLIFailure.usage("Unknown scenario '\(value)'", hint: "List scenarios with: wm debug list")
        }
        try requireAccessibility()

        let store = ProfileStore()
        let events = ctx.events
        let json = ctx.json
        let outcome = runOnMain { () -> DebugRunOutcome in
            do {
                try DebugTestRunner.installFixtureProfiles(into: store)
            } catch {
                return DebugRunOutcome(results: [], error: "fixture install failed: \(error.localizedDescription)")
            }
            let runner = DebugTestRunner(store: store)
            var results: [DebugRunResult] = []
            for scenario in scenarios {
                results.append(await runner.run(scenario) { event in
                    guard let progress = DebugRunReport.progress(for: event, scenario: scenario) else { return }
                    if json { events.emit(progress.event, progress.fields) }
                    else if case .check(let check) = event {
                        FileHandle.standardError.write(Data("\(check.passed ? "PASS" : "FAIL") \(check.name): \(check.detail)\n".utf8))
                    }
                })
            }
            return DebugRunOutcome(results: results, error: nil)
        }

        var resultPath: String?
        var writeError: String?
        do {
            resultPath = try DebugRunReport.write(results: outcome.results, error: outcome.error).path
        } catch {
            writeError = "\(error.localizedDescription)"
        }
        if let error = outcome.error {
            throw CLIFailure(.runtime, code: "debug_run_failed", message: error)
        }

        let passed = !outcome.results.isEmpty && outcome.results.allSatisfy(\.passed)
        var data = DebugRunReport.document(results: outcome.results, error: nil)
        if case .object(var root) = data {
            root["resultPath"] = resultPath.map { .string($0) } ?? .null
            root["resultWriteError"] = writeError.map { .string($0) } ?? .null
            data = .object(root)
        }
        let lines = outcome.results.map { result -> String in
            let checks = result.checks.filter(\.passed).count
            return "\(result.passed ? "PASS" : "FAIL")  \(result.scenario.title)  (\(checks)/\(result.checks.count) checks)"
        }
        let text = (lines + [resultPath.map { "results: \($0)" } ?? "results not written: \(writeError ?? "unknown")"])
            .joined(separator: "\n")
        return CLIResult(data: data, exit: passed ? .ok : .partial, text: text)
    })
}
