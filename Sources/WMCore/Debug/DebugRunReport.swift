import Foundation

/// The debug-run.json document shared by the app's headless run (`--debug-run`) and `wm debug run`.
public enum DebugRunReport {
    public static var resultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Windows Manager/debug-run.json")
    }

    /// The document as JSON values. `passed` is true only when there are results, no error and every scenario passed.
    public static func document(results: [DebugRunResult], error: String?, generatedAt: Date = Date()) -> JSONValue {
        let items: [JSONValue] = results.map { result in
            .object([
                "scenario": .string(result.scenarioID),
                "title": .string(result.title),
                "status": .string(result.status.rawValue),
                "passed": .bool(result.passed),
                "checks": .array(result.checks.map { check in
                    .object(["id": .string(check.id), "name": .string(check.name),
                             "passed": .bool(check.passed), "detail": .string(check.detail)])
                }),
                "log": .array(result.log.map { .string($0) }),
            ])
        }
        var root: [String: JSONValue] = [
            "generatedAt": .string(ISO8601DateFormatter().string(from: generatedAt)),
            "passed": .bool(error == nil && !results.isEmpty && results.allSatisfy(\.passed)),
            "results": .array(items),
        ]
        if let error { root["error"] = .string(error) }
        return .object(root)
    }

    /// Last status per scenario id from a debug-run.json document (older files without "status" map passed to PASS/FAIL).
    public static func lastStatuses(from data: Data) -> [String: DebugRunStatus] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = root, case .array(let items)? = obj["results"] else { return [:] }
        var out: [String: DebugRunStatus] = [:]
        for item in items {
            guard case .object(let o) = item, case .string(let id)? = o["scenario"] else { continue }
            if case .string(let st)? = o["status"], let status = DebugRunStatus(rawValue: st) { out[id] = status }
            else if case .bool(let ok)? = o["passed"] { out[id] = ok ? .pass : .fail }
        }
        return out
    }

    /// Scenarios for a value: "all" (any case) or one raw value. Nil when the value names no scenario.
    public static func scenarios(for value: String) -> [DebugScenarioID]? {
        if value.lowercased() == "all" { return DebugScenarioID.allCases }
        return DebugScenarioID(rawValue: value).map { [$0] }
    }

    /// The NDJSON event for one runner event (`phase`, `step` or `check`). Log lines stay in debug-tests.log only.
    public static func progress(for event: DebugEvent, scenarioID: String) -> (event: String, fields: [String: JSONValue])? {
        let base: [String: JSONValue] = ["scenario": .string(scenarioID)]
        switch event {
        case .phase(let phase):
            return ("phase", base.merging(["phase": .string(phase)]) { $1 })
        case .step(let row):
            return ("step", base.merging([
                "id": .string(row.id), "kind": .string(row.kind), "target": .string(row.target),
                "status": .string(row.status.rawValue), "detail": .string(row.detail),
            ]) { $1 })
        case .check(let check):
            return ("check", base.merging([
                "id": .string(check.id), "name": .string(check.name),
                "passed": .bool(check.passed), "detail": .string(check.detail),
            ]) { $1 })
        case .log:
            return nil
        }
    }

    /// Writes debug-run.json (atomically) and returns its URL.
    @discardableResult
    public static func write(results: [DebugRunResult], error: String?) throws -> URL {
        let url = resultURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document(results: results, error: error))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }
}
