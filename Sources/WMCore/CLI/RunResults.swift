import CoreGraphics
import Foundation

// Pure, JSON-encodable results for `wm run`, `wm plan`, `wm capture` and `wm verify` (P6.91).
// No live windows are read here: the commands feed in a Profile, a RestorePlan or a RestoreReport.

// MARK: - Profile lookup

public enum CLIProfileLookup {
    public enum Outcome: Equatable, Sendable {
        case found(UUID)
        case notFound
        case ambiguous([String])
    }

    /// Resolves `query` as an id (case-insensitive UUID), then an exact name (case-insensitive), then a unique
    /// name prefix.
    public static func resolve(_ query: String, in summaries: [ProfileSummary]) -> Outcome {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: q), summaries.contains(where: { $0.id == id }) { return .found(id) }
        let exact = summaries.filter { $0.name.caseInsensitiveCompare(q) == .orderedSame }
        if exact.count == 1 { return .found(exact[0].id) }
        if exact.count > 1 { return .ambiguous(exact.map { $0.id.uuidString }) }
        let prefix = summaries.filter { !q.isEmpty && $0.name.lowercased().hasPrefix(q.lowercased()) }
        if prefix.count == 1 { return .found(prefix[0].id) }
        if prefix.count > 1 { return .ambiguous(prefix.map { $0.name }) }
        return .notFound
    }
}

// MARK: - Plan

public struct CLIRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(_ r: CGRect) { x = r.minX; y = r.minY; width = r.width; height = r.height }
}

public struct CLIPlanStep: Codable, Equatable, Sendable {
    public var kind: String
    public var description: String
    public var app: String
    public var bundleID: String?
    public var snapshotID: UUID?
    public var windowID: UInt32?
    public var title: String?
    public var frame: CLIRect?
    public var from: CLIRect?
    public var desktop: Int?

    public init(_ step: RestoreStep) {
        description = step.description
        app = step.app.name
        bundleID = step.app.bundleID
        snapshotID = step.target?.snapshotID
        windowID = step.target?.windowID
        title = step.target?.title
        switch step {
        case .launch: kind = "launch"
        case .exitFullScreen: kind = "exitFullScreen"
        case .unminimize: kind = "unminimize"
        case .addDesktop(_, let count): kind = "addDesktop"; desktop = count
        case .moveToDesktop(_, let d, _, _, _, _): kind = "moveToDesktop"; desktop = d
        case .setFrame(_, let f, let from, _): kind = "setFrame"; frame = CLIRect(f); self.from = CLIRect(from)
        case .enterFullScreen: kind = "enterFullScreen"
        case .minimize: kind = "minimize"
        case .raise(_, let z): kind = "raise"; desktop = nil; _ = z
        case .hideApp: kind = "hideApp"
        case .needsConfirmationQuit: kind = "needsConfirmationQuit"
        }
    }
}

public struct CLIPlanPhase: Codable, Equatable, Sendable {
    public var phase: String
    public var title: String
    public var steps: [CLIPlanStep]
}

public struct CLIUnmatched: Codable, Equatable, Sendable {
    public var snapshotID: UUID
    public var app: String
    public var title: String?
    public var reason: String
    public init(_ u: UnmatchedSnapshot) { snapshotID = u.snapshotID; app = u.app.name; title = u.title; reason = u.reason }
}

public struct CLIMissingDesktop: Codable, Equatable, Sendable {
    public var number: Int
    public var display: String
    public var available: Int
    public init(_ m: MissingDesktop) { number = m.number; display = m.displayName; available = m.available }
}

/// The dry-run plan grouped by phase, the way the Studio's restore preview shows it.
public struct CLIPlanResult: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var profileName: String
    public var stepCount: Int
    public var phases: [CLIPlanPhase]
    public var warnings: [String]
    public var unmatched: [CLIUnmatched]
    public var missingDesktops: [CLIMissingDesktop]
    public var ambiguous: [UUID]

    public init(profileID: UUID, plan: RestorePlan) {
        self.profileID = profileID
        profileName = plan.profileName
        stepCount = plan.steps.count
        phases = plan.phases.map { p in
            CLIPlanPhase(phase: p.rawValue, title: p.title, steps: plan.steps(in: p).map(CLIPlanStep.init))
        }
        warnings = plan.warnings
        unmatched = plan.unmatched.map(CLIUnmatched.init)
        missingDesktops = plan.missingDesktops.map(CLIMissingDesktop.init)
        ambiguous = plan.ambiguous
    }

    /// Exit code: 6 when saved windows have no live window.
    public var exit: CLIExitCode { unmatched.isEmpty ? .ok : .partial }
}

// MARK: - Run

public enum CLIRunEvents {
    /// Fields of the `{"event":"progress",...}` NDJSON line for one engine event.
    public static func fields(for event: RestoreProgress) -> [String: JSONValue] {
        switch event {
        case .scanning: return ["stage": .string("scanning")]
        case .planned(let plan):
            return ["stage": .string("planned"), "steps": .int(plan.steps.count),
                    "unmatched": .int(plan.unmatched.count), "warnings": .int(plan.warnings.count)]
        case .launching(let apps):
            return ["stage": .string("launching"), "apps": .array(apps.map { .string($0.name) })]
        case .rescanning: return ["stage": .string("rescanning")]
        case .stepStarted(let i, let n, let d):
            return ["stage": .string("step_started"), "index": .int(i), "total": .int(n), "description": .string(d)]
        case .stepFinished(let i, let n, let d, let status, let elapsed):
            var f: [String: JSONValue] = ["stage": .string("step_finished"), "index": .int(i), "total": .int(n),
                                          "description": .string(d), "elapsed": .double(elapsed)]
            switch status {
            case .done: f["status"] = .string("done")
            case .skipped(let r): f["status"] = .string("skipped"); f["reason"] = .string(r)
            case .failed(let r): f["status"] = .string("failed"); f["reason"] = .string(r)
            }
            return f
        case .settling: return ["stage": .string("settling")]
        case .finished(let report):
            return ["stage": .string("finished"), "summary": .string(report.summary), "clean": .bool(report.isClean)]
        }
    }
}

public enum CLIRunOutcome {
    /// 0 for a clean report, 6 when windows were not found, failed or the run was cancelled.
    public static func exit(for report: RestoreReport) -> CLIExitCode { report.isClean ? .ok : .partial }
}

// MARK: - Capture

public enum CLICaptureFilter {
    /// Window ids of `profile` matched by any selector. Selectors: `app:<name or bundle id>`, a bare app name or
    /// bundle id, `desktop:<N>` (1-based Desktop on any monitor), `fullscreen`, `minimized`, `all`.
    public static func windowIDs(in profile: Profile, selectors: [String]) -> Set<UUID> {
        var picked = Set<UUID>()
        let index = ProfileSpaceIndex(profile: profile)
        for raw in selectors {
            let sel = raw.trimmingCharacters(in: .whitespaces)
            let lower = sel.lowercased()
            if lower == "all" { picked.formUnion(profile.windows.map(\.id)); continue }
            if lower == "fullscreen" { picked.formUnion(profile.windows.filter(\.isFullScreen).map(\.id)); continue }
            if lower == "minimized" { picked.formUnion(profile.windows.filter(\.isMinimized).map(\.id)); continue }
            if lower.hasPrefix("desktop:"), let n = Int(lower.dropFirst(8)) {
                for space in index.spaces where space.desktopNumber == n { picked.formUnion(space.windowIDs) }
                continue
            }
            let name = lower.hasPrefix("app:") ? String(lower.dropFirst(4)) : lower
            picked.formUnion(profile.windows.filter {
                $0.app.name.lowercased() == name || $0.app.bundleID?.lowercased() == name
            }.map(\.id))
        }
        return picked
    }
}

public struct CLICaptureResult: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var windowCount: Int
    public var capturedWindowCount: Int
    public var displayCount: Int
    public var apps: [String]
    public var warnings: [String]

    public init(profile: Profile, capturedWindowCount: Int, warnings: [String]) {
        id = profile.id
        name = profile.name
        windowCount = profile.windows.count
        self.capturedWindowCount = capturedWindowCount
        displayCount = profile.displays.count
        var seen = Set<String>()
        apps = profile.windows.map(\.app.name).filter { seen.insert($0).inserted }
        self.warnings = warnings
    }
}

// MARK: - Verify

public struct CLIVerifyCheck: Codable, Equatable, Sendable {
    /// ok | mismatch | missing | will_launch | skipped | parked
    public var status: String
    public var snapshotID: UUID
    public var app: String
    public var title: String?
    public var detail: String?
    /// What a restore would still do to this window.
    public var pendingSteps: [String]
    public var passed: Bool
}

public struct CLIVerifyResult: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var profileName: String
    public var ok: Bool
    public var checked: Int
    public var mismatches: Int
    public var windows: [CLIVerifyCheck]
    public var missingDesktops: [CLIMissingDesktop]
    public var warnings: [String]

    /// Diffs the profile against the plan a restore would make now (the plan comes from live state).
    public init(profile: Profile, plan: RestorePlan) {
        let status = ProfileLiveStatus(profile: profile, plan: plan)
        var checks: [CLIVerifyCheck] = []
        for w in profile.windows {
            let pending = plan.steps.filter { $0.target?.snapshotID == w.id && $0.phase != .raise }.map(\.description)
            func check(_ s: String, _ passed: Bool, _ detail: String? = nil, _ steps: [String] = []) -> CLIVerifyCheck {
                CLIVerifyCheck(status: s, snapshotID: w.id, app: w.app.name, title: w.title, detail: detail,
                               pendingSteps: steps, passed: passed)
            }
            if status.parked.contains(w.id) {
                checks.append(check("parked", true, "may be in the Stage Manager strip"))
                continue
            }
            switch status.windows[w.id] {
            case .inPlace?: checks.append(check("ok", true))
            case .willMove?: checks.append(check("mismatch", false, "not where the profile says", pending))
            case .willLaunch?: checks.append(check("will_launch", false, "app is not running", pending))
            case .notFound(let reason)?: checks.append(check("missing", false, reason))
            case .notRestored?, nil: checks.append(check("skipped", true, "restore is switched off for this window"))
            }
        }
        profileID = profile.id
        profileName = profile.name
        windows = checks
        checked = checks.filter { $0.status != "skipped" && $0.status != "parked" }.count
        mismatches = checks.filter { !$0.passed }.count
        ok = mismatches == 0
        missingDesktops = plan.missingDesktops.map(CLIMissingDesktop.init)
        warnings = plan.warnings
    }

    public var exit: CLIExitCode { ok ? .ok : .partial }
}
