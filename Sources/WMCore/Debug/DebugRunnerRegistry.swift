import Foundation

// Scenario runner registry (P6.126): scenario id -> fixture profile + scramble + verify rules.
// Pure data, no live window access, so `--list`, the panel rows and the tests can use it freely.

/// How the live desktop is scrambled before the restore.
public enum DebugScrambleKind: String, Sendable {
    case cold, wrongPlace, mixed, extras, rerun, home
    /// Power-user scenarios: open the profile apps, then shift every window +200 and halve its size.
    case shifted
}

public struct DebugRunnerEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    /// Set for the original S1..S7/Home scenarios, nil for power-user scenarios.
    public let legacy: DebugScenarioID?
    /// Name of the fixture profile the scenario restores.
    public let fixtureProfile: String
    public let scramble: DebugScrambleKind
    /// Verify rule ids, see `DebugRunnerRegistry.knownRules`.
    public let verifyRules: [String]
    public let requiredBundleIDs: [String]
    public let requiredDesktops: Int
    public let requiredDisplays: Int
    public let expectsSizeLimited: [String]
}

public enum DebugRunnerRegistry {
    /// frames/extras: DebugVerify.evaluate | duplicate-ids, size-limited, idempotence: DebugVerifyRules |
    /// inconclusive: Stage Manager, too few displays or missing permission end INCONCLUSIVE; a missing app ends SKIPPED.
    public static let knownRules = ["frames", "extras", "duplicate-ids", "size-limited", "idempotence", "inconclusive"]

    public static let entries: [DebugRunnerEntry] = legacyEntries + powerUserEntries

    private static var legacyEntries: [DebugRunnerEntry] {
        DebugScenarioID.allCases.map { s in
            let kind: DebugScrambleKind
            switch s {
            case .s1Cold: kind = .cold
            case .s2WrongPlace: kind = .wrongPlace
            case .s3Mixed: kind = .mixed
            case .s4Extras: kind = .extras
            case .s7Rerun: kind = .rerun
            case .home: kind = .home
            }
            var rules = ["frames"]
            if s == .s4Extras { rules.append("extras") }
            if s == .s7Rerun { rules.append("idempotence") }
            return DebugRunnerEntry(id: s.rawValue, title: s.title, summary: s.summary, legacy: s,
                                    fixtureProfile: s == .home ? "Home" : "Challenge Work", scramble: kind,
                                    verifyRules: rules + ["duplicate-ids"], requiredBundleIDs: [],
                                    requiredDesktops: 1, requiredDisplays: 1, expectsSizeLimited: [])
        }
    }

    private static var powerUserEntries: [DebugRunnerEntry] {
        DebugFixtures.scenarios.map { spec in
            var rules = ["frames", "duplicate-ids", "inconclusive"]
            if !spec.expectsSizeLimited.isEmpty { rules.append("size-limited") }
            if spec.expectsIdempotent { rules.append("idempotence") }
            return DebugRunnerEntry(id: spec.id, title: spec.title, summary: spec.summary, legacy: nil,
                                    fixtureProfile: DebugFixtures.profile(for: spec.id)?.name ?? spec.title,
                                    scramble: .shifted, verifyRules: rules, requiredBundleIDs: spec.requiredBundleIDs,
                                    requiredDesktops: spec.requiredDesktops, requiredDisplays: spec.requiredDisplays,
                                    expectsSizeLimited: spec.expectsSizeLimited)
        }
    }

    public static func entry(id: String) -> DebugRunnerEntry? { entries.first { $0.id == id } }

    /// "all" (any case) or one id. Nil when the value names no scenario.
    public static func resolve(_ value: String) -> [DebugRunnerEntry]? {
        if value.lowercased() == "all" { return entries }
        return entry(id: value).map { [$0] }
    }

    /// Rows for `wm debug run --list`; `last` maps scenario id to its last status.
    public static func listJSON(last: [String: DebugRunStatus] = [:]) -> JSONValue {
        .object(["scenarios": .array(entries.map { e in
            .object(["id": .string(e.id), "title": .string(e.title), "summary": .string(e.summary),
                     "fixtureProfile": .string(e.fixtureProfile), "scramble": .string(e.scramble.rawValue),
                     "verifyRules": .array(e.verifyRules.map { .string($0) }),
                     "requiredDesktops": .int(e.requiredDesktops), "requiredDisplays": .int(e.requiredDisplays),
                     "last": last[e.id].map { .string($0.rawValue) } ?? .null])
        })])
    }

    public static func listText(last: [String: DebugRunStatus] = [:]) -> String {
        entries.map { "\($0.id)\t\(last[$0.id]?.rawValue ?? "-")\t\($0.title) - \($0.summary)" }.joined(separator: "\n")
    }

    /// Last statuses from debug-run.json, empty when there is none.
    public static func lastStatuses() -> [String: DebugRunStatus] {
        guard let data = try? Data(contentsOf: DebugRunReport.resultURL) else { return [:] }
        return DebugRunReport.lastStatuses(from: data)
    }
}
