import Foundation

// What a restore did (phase P2.8): one record per step with its status and time, one outcome per saved window,
// the apps that were launched, the saved windows that were not found, totals and a one-line summary.
// Plain Codable data, so the UI can show it and the lab command can save it.

/// How one step ended.
public enum RestoreStepStatus: Equatable, Sendable, Codable {
    case done
    /// Nothing was done on purpose: dry run, cancelled, already in place, needs confirmation.
    case skipped(String)
    case failed(String)

    public var isDone: Bool { if case .done = self { return true } else { return false } }
    public var isFailed: Bool { if case .failed = self { return true } else { return false } }
    public var isSkipped: Bool { if case .skipped = self { return true } else { return false } }

    /// "done", "skipped: dry run", "failed: window not reachable by Accessibility".
    public var text: String {
        switch self {
        case .done: return "done"
        case .skipped(let reason): return "skipped: \(reason)"
        case .failed(let reason): return "failed: \(reason)"
        }
    }

    /// The reason of a skipped or failed step.
    public var reason: String? {
        switch self {
        case .done: return nil
        case .skipped(let reason), .failed(let reason): return reason
        }
    }

    // JSON form: {"status": "done"} or {"status": "skipped" | "failed", "reason": "..."}.
    private enum CodingKeys: String, CodingKey {
        case status, reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decode(String.self, forKey: .status)
        switch status {
        case "done":
            self = .done
        case "skipped":
            self = .skipped(try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case "failed":
            self = .failed(try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [CodingKeys.status],
                                                    debugDescription: "Unknown step status \(status)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .done:
            try c.encode("done", forKey: .status)
        case .skipped(let reason):
            try c.encode("skipped", forKey: .status)
            try c.encode(reason, forKey: .reason)
        case .failed(let reason):
            try c.encode("failed", forKey: .status)
            try c.encode(reason, forKey: .reason)
        }
    }
}

public extension RestoreStep {
    /// A stable name for the kind of step, for reports ("setFrame", "hideApp", ...).
    var kind: String {
        switch self {
        case .launch: return "launch"
        case .exitFullScreen: return "exitFullScreen"
        case .unminimize: return "unminimize"
        case .addDesktop: return "addDesktop"
        case .moveToDesktop: return "moveToDesktop"
        case .setFrame: return "setFrame"
        case .enterFullScreen: return "enterFullScreen"
        case .minimize: return "minimize"
        case .raise: return "raise"
        case .hideApp: return "hideApp"
        case .needsConfirmationQuit: return "quit"
        }
    }
}

/// One executed (or skipped) step.
public struct RestoreStepRecord: Codable, Equatable, Sendable {
    /// 1-based, in execution order across the whole run.
    public var index: Int
    public var phase: RestorePhase
    /// `RestoreStep.kind`, or "reapplyFrame" for a frame set again after a window drifted.
    public var kind: String
    public var description: String
    public var snapshotID: UUID?
    public var windowID: UInt32?
    public var app: String
    public var status: RestoreStepStatus
    public var elapsed: TimeInterval
    /// Extra detail on success, such as "minimum size reached".
    public var note: String?

    public init(index: Int, phase: RestorePhase, kind: String, description: String, snapshotID: UUID? = nil,
                windowID: UInt32? = nil, app: String, status: RestoreStepStatus, elapsed: TimeInterval = 0,
                note: String? = nil) {
        self.index = index
        self.phase = phase
        self.kind = kind
        self.description = description
        self.snapshotID = snapshotID
        self.windowID = windowID
        self.app = app
        self.status = status
        self.elapsed = elapsed
        self.note = note
    }
}

/// How one saved window ended up.
public enum RestoreWindowOutcomeKind: String, Codable, Sendable {
    /// Every step it needed is done (or it was in place already).
    case placed
    /// Some steps are done and some failed or were skipped.
    case partial
    /// Its steps failed.
    case failed
    /// No live window was found for it.
    case notFound
    /// Dry run: steps are planned for it.
    case planned
    /// The run was cancelled before its steps ran.
    case notDone
}

public struct RestoreWindowOutcome: Codable, Equatable, Sendable {
    public var snapshotID: UUID
    public var app: AppRef
    public var title: String?
    /// The live window that was used, nil when none was found.
    public var windowID: UInt32?
    public var outcome: RestoreWindowOutcomeKind
    /// Reasons and details, for people.
    public var notes: [String]

    public init(snapshotID: UUID, app: AppRef, title: String?, windowID: UInt32? = nil,
                outcome: RestoreWindowOutcomeKind, notes: [String] = []) {
        self.snapshotID = snapshotID
        self.app = app
        self.title = title
        self.windowID = windowID
        self.outcome = outcome
        self.notes = notes
    }
}

/// What happened to one app that had to be launched.
public struct RestoreLaunchRecord: Codable, Equatable, Sendable {
    public var app: AppRef
    /// "launched", "already running", "not found", "timed out", "failed: ...".
    public var result: String
    /// True when the app was opened by this run.
    public var launched: Bool
    public var windowCount: Int
    public var elapsed: TimeInterval

    public init(app: AppRef, result: String, launched: Bool, windowCount: Int = 0, elapsed: TimeInterval = 0) {
        self.app = app
        self.result = result
        self.launched = launched
        self.windowCount = windowCount
        self.elapsed = elapsed
    }
}

public struct RestoreTotals: Codable, Equatable, Sendable {
    public var steps = 0
    public var done = 0
    public var skipped = 0
    public var failed = 0
    public var windowsPlaced = 0
    public var windowsPartial = 0
    public var windowsFailed = 0
    public var windowsNotFound = 0
    /// Dry run: windows that have steps.
    public var windowsPlanned = 0
    public var windowsNotDone = 0
    public var appsLaunched = 0
    public var appsHidden = 0
    public var appsNeedingConfirmation = 0
    /// Frames set again after a window drifted.
    public var driftCorrections = 0

    public init() {}
}

public struct RestoreReport: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var profileName: String
    public var dryRun: Bool
    public var cancelled: Bool
    public var startedAt: Date
    public var finishedAt: Date
    public var elapsed: TimeInterval
    /// Every step in the order it ran (planned steps with status "skipped: dry run" for a dry run).
    public var steps: [RestoreStepRecord]
    /// One entry per window of the profile that was meant to be restored.
    public var windows: [RestoreWindowOutcome]
    public var launched: [RestoreLaunchRecord]
    /// Saved windows without a live window.
    public var unmatched: [UnmatchedSnapshot]
    public var ambiguous: [UUID]
    /// Apps the profile wants quit; the UI has to ask before anything is quit.
    public var needsConfirmation: [AppRef]
    public var warnings: [String]
    public var totals: RestoreTotals
    public var summary: String

    public init(profileID: UUID, profileName: String, dryRun: Bool = false, startedAt: Date = Date()) {
        self.profileID = profileID
        self.profileName = profileName
        self.dryRun = dryRun
        self.cancelled = false
        self.startedAt = startedAt
        self.finishedAt = startedAt
        self.elapsed = 0
        self.steps = []
        self.windows = []
        self.launched = []
        self.unmatched = []
        self.ambiguous = []
        self.needsConfirmation = []
        self.warnings = []
        self.totals = RestoreTotals()
        self.summary = ""
    }

    /// True when nothing failed, nothing was cancelled and every wanted window was found.
    public var isClean: Bool {
        !cancelled && totals.failed == 0 && totals.windowsNotFound == 0 && totals.windowsFailed == 0
    }

    // MARK: Finishing

    /// Fills `windows`, `totals` and `summary` from the records. Call once when the run is over.
    public mutating func finish(profile: Profile, finishedAt: Date = Date(), elapsed: TimeInterval) {
        self.finishedAt = finishedAt
        self.elapsed = elapsed
        windows = Self.windowOutcomes(profile: profile, records: steps, unmatched: unmatched, dryRun: dryRun)
        totals = Self.totals(steps: steps, windows: windows, launched: launched, needsConfirmation: needsConfirmation)
        summary = makeSummary()
    }

    /// One outcome per window of the profile with `restore == true`, in profile order. Pure.
    public static func windowOutcomes(profile: Profile, records: [RestoreStepRecord],
                                      unmatched: [UnmatchedSnapshot], dryRun: Bool) -> [RestoreWindowOutcome] {
        var outcomes: [RestoreWindowOutcome] = []
        for snapshot in profile.windows where snapshot.restore {
            if let missing = unmatched.first(where: { $0.snapshotID == snapshot.id }) {
                outcomes.append(RestoreWindowOutcome(snapshotID: snapshot.id, app: snapshot.app, title: snapshot.title,
                                                     outcome: .notFound, notes: [missing.reason]))
                continue
            }
            let mine = records.filter { $0.snapshotID == snapshot.id }
            let windowID = mine.compactMap(\.windowID).first
            let notes = mine.compactMap { record -> String? in
                if let reason = record.status.reason, !(record.status.isSkipped && dryRun) {
                    return "\(record.kind): \(reason)"
                }
                return record.note.map { "\(record.kind): \($0)" }
            }
            let done = mine.filter { $0.status.isDone }.count
            let failed = mine.filter { $0.status.isFailed }.count
            let skipped = mine.count - done - failed

            let kind: RestoreWindowOutcomeKind
            if mine.isEmpty {
                kind = .placed
            } else if dryRun {
                kind = .planned
            } else if failed > 0 {
                kind = done > 0 ? .partial : .failed
            } else if skipped > 0 {
                kind = done > 0 ? .partial : .notDone
            } else {
                kind = .placed
            }
            var allNotes = notes
            if mine.isEmpty { allNotes.append("already in place") }
            outcomes.append(RestoreWindowOutcome(snapshotID: snapshot.id, app: snapshot.app, title: snapshot.title,
                                                 windowID: windowID, outcome: kind, notes: allNotes))
        }
        return outcomes
    }

    /// Counts for the report. Pure.
    public static func totals(steps: [RestoreStepRecord], windows: [RestoreWindowOutcome],
                              launched: [RestoreLaunchRecord], needsConfirmation: [AppRef]) -> RestoreTotals {
        var totals = RestoreTotals()
        totals.steps = steps.count
        totals.done = steps.filter { $0.status.isDone }.count
        totals.failed = steps.filter { $0.status.isFailed }.count
        totals.skipped = steps.filter { $0.status.isSkipped }.count
        for window in windows {
            switch window.outcome {
            case .placed: totals.windowsPlaced += 1
            case .partial: totals.windowsPartial += 1
            case .failed: totals.windowsFailed += 1
            case .notFound: totals.windowsNotFound += 1
            case .planned: totals.windowsPlanned += 1
            case .notDone: totals.windowsNotDone += 1
            }
        }
        totals.appsLaunched = launched.filter(\.launched).count
        totals.appsHidden = steps.filter { $0.kind == "hideApp" && $0.status.isDone }.count
        totals.appsNeedingConfirmation = needsConfirmation.count
        totals.driftCorrections = steps.filter { $0.kind == "reapplyFrame" && $0.status.isDone }.count
        return totals
    }

    /// "12 windows placed, 2 launched, 1 not found". A dry run says what would happen instead.
    public func makeSummary() -> String {
        func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
            "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
        }
        var parts: [String] = []
        if dryRun {
            parts.append(count(totals.windowsPlanned, "window") + " to change")
            if totals.windowsPlaced > 0 { parts.append("\(totals.windowsPlaced) already in place") }
            let toLaunch = steps.filter { $0.kind == "launch" }.count
            if toLaunch > 0 { parts.append(count(toLaunch, "app") + " to launch") }
            let toHide = steps.filter { $0.kind == "hideApp" }.count
            if toHide > 0 { parts.append(count(toHide, "app") + " to hide") }
        } else {
            if totals.windowsPartial > 0 { parts.append("\(totals.windowsPartial) partly placed") }
            if totals.windowsFailed > 0 { parts.append("\(totals.windowsFailed) failed") }
            if totals.windowsNotDone > 0 { parts.append("\(totals.windowsNotDone) not done") }
            if totals.appsLaunched > 0 { parts.append("\(totals.appsLaunched) launched") }
            if totals.appsHidden > 0 { parts.append("\(totals.appsHidden) hidden") }
        }
        if totals.windowsNotFound > 0 { parts.append("\(totals.windowsNotFound) not found") }
        if totals.appsNeedingConfirmation > 0 {
            parts.append("\(count(totals.appsNeedingConfirmation, "app")) to quit need confirmation")
        }
        if !dryRun && (totals.windowsPlaced > 0 || parts.isEmpty) {
            // "12 windows placed" leads the line, but "0 windows placed" is left out when there is more to say.
            parts.insert(count(totals.windowsPlaced, "window") + " placed", at: 0)
        }
        var text = parts.joined(separator: ", ")
        if dryRun { text = "Dry run: " + text }
        if cancelled { text = "Cancelled: " + text }
        return text
    }

    // MARK: JSON

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func jsonData() throws -> Data { try Self.makeEncoder().encode(self) }

    public static func decode(_ data: Data) throws -> RestoreReport { try makeDecoder().decode(RestoreReport.self, from: data) }
}
