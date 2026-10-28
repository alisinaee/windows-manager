import AppKit
import Foundation
import WMCore

/// Headless debug run (P6.71). `--debug-run [scenario|all]` on the command line, or the file /tmp/wm-debug-run.txt
/// holding the same value, runs the live scenarios right after launch without any menu bar click. The combined
/// results go to ~/Library/Logs/Windows Manager/debug-run.json. Every event still goes to debug-tests.log.
enum DebugHeadlessRun {
    static let triggerPath = "/tmp/wm-debug-run.txt"

    /// The requested value ("all", a scenario raw value), or nil when no run was asked for.
    /// The trigger file is read and deleted here, so a stale file cannot start a second run.
    static func requestedValue(arguments: [String]) -> String? {
        var fromFile: String?
        if FileManager.default.fileExists(atPath: triggerPath) {
            let text = (try? String(contentsOfFile: triggerPath, encoding: .utf8)) ?? ""
            fromFile = text.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(atPath: triggerPath)
        }
        if let index = arguments.firstIndex(of: "--debug-run") {
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") { return arguments[index + 1] }
            return "all"
        }
        guard let fromFile else { return nil }
        return fromFile.isEmpty ? "all" : fromFile
    }

    /// Scenarios for a value: "all" (any case) or one raw value. Nil when the value names no scenario.
    static func scenarios(for value: String) -> [DebugScenarioID]? {
        if value.lowercased() == "all" { return DebugScenarioID.allCases }
        return DebugScenarioID(rawValue: value).map { [$0] }
    }

    /// Called once from applicationDidFinishLaunching. Does nothing unless a run was requested.
    static func startIfRequested() {
        guard !CommandLine.arguments.contains("--self-check") else { return }
        guard let value = requestedValue(arguments: CommandLine.arguments) else { return }
        AppInfo.logger.notice("Headless debug run requested: \(value, privacy: .public)")
        Task { @MainActor in
            // AppState is created by the App before the delegate's didFinishLaunching runs.
            guard let state = AppState.current else {
                writeJSON(results: [], error: "app state not ready")
                return
            }
            await execute(value, state: state)
        }
    }

    @MainActor
    private static func execute(_ value: String, state: AppState) async {
        guard let scenarios = scenarios(for: value) else {
            writeJSON(results: [], error: "unknown scenario \(value)")
            return
        }
        // Debug mode shows the Debug window, the same as turning it on from the menu.
        state.debugMode = true
        do {
            try DebugTestRunner.installFixtureProfiles(into: state.store)
        } catch {
            writeJSON(results: [], error: "fixture install failed: \(error.localizedDescription)")
            return
        }
        let runner = DebugTestRunner(store: state.store)
        var results: [DebugRunResult] = []
        for scenario in scenarios {
            AppInfo.logger.notice("Headless debug scenario \(scenario.rawValue, privacy: .public)")
            results.append(await runner.run(scenario) { _ in })
        }
        writeJSON(results: results, error: nil)
        AppInfo.logger.notice("Headless debug run finished: \(results.allSatisfy(\.passed) ? "passed" : "failed", privacy: .public)")
    }

    static var resultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Windows Manager/debug-run.json")
    }

    static func jsonText(results: [DebugRunResult], error: String?) -> String {
        let items: [[String: Any]] = results.map { result in
            [
                "scenario": result.scenario.rawValue,
                "passed": result.passed,
                "checks": result.checks.map { check -> [String: Any] in
                    ["id": check.id, "name": check.name, "passed": check.passed, "detail": check.detail]
                },
                "log": result.log,
            ]
        }
        var root: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "passed": error == nil && !results.isEmpty && results.allSatisfy(\.passed),
            "results": items,
        ]
        if let error { root["error"] = error }
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private static func writeJSON(results: [DebugRunResult], error: String?) {
        let url = resultURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(jsonText(results: results, error: error).utf8).write(to: url, options: .atomic)
            AppInfo.logger.notice("Headless debug results written to \(url.path, privacy: .public)")
        } catch {
            AppInfo.logger.error("Headless debug results not written: \(String(describing: error), privacy: .public)")
        }
    }
}
