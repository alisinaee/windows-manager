import Foundation
import WMCore

private let debugResultsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Windows Manager/debug-run.json")

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

    // TODO(debug run): deliberately not implemented in the CLI. `wm debug run` moves real windows, so it must
    // require --yes and a running app (the app's headless path is `--debug-run`, see DebugHeadlessRun).
    // Add it only after the app IPC can start a run and report back.
}
