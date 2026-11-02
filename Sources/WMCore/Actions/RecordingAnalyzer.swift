import Foundation

/// One action found in a recording: the steps of one app's stretch of work, with their times so the review
/// can add the user's own pauses back.
public struct DetectedAction: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var bundleID: String?
    public var steps: [TimedStep]

    public init(id: UUID = UUID(), name: String, bundleID: String?, steps: [TimedStep]) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.steps = steps
    }

    /// The action's steps; with `keepTiming` a `.delay` goes in wherever the user paused.
    public func resolvedSteps(keepTiming: Bool) -> [ActionStep] {
        guard keepTiming else { return steps.map(\.step) }
        var out: [ActionStep] = []
        for (i, entry) in steps.enumerated() {
            if i > 0, let pause = RecordingAnalyzer.pause(from: steps[i - 1].time, to: entry.time) {
                out.append(.delay(seconds: pause))
            }
            out.append(entry.step)
        }
        return out
    }

    public func profileAction(keepTiming: Bool, phase: ActionPhase = .afterRestore) -> ProfileAction {
        ProfileAction(id: id, name: name, phase: phase, steps: resolvedSteps(keepTiming: keepTiming))
    }
}

public struct RecordingAnalysis: Equatable, Sendable {
    /// Apps the user opened that have a normal window at Stop, in the order they were opened. The profile restore
    /// opens and places these, so their launch steps are not part of any action.
    public var layoutBundleIDs: [String]
    public var actions: [DetectedAction]
}

/// Splits a recording into a window layout part and separate actions. Pure: the caller supplies which apps
/// have windows right now.
public enum RecordingAnalyzer {
    /// The user must have paused longer than this for a delay to be added.
    public static let pauseThreshold: TimeInterval = 1
    public static let maxPause: TimeInterval = 10

    /// Rounded to 0.5 s and capped at 10 s; nil when the gap is not a pause.
    public static func pause(from: TimeInterval, to: TimeInterval) -> TimeInterval? {
        let gap = to - from
        guard gap > pauseThreshold else { return nil }
        return min(maxPause, (gap * 2).rounded() / 2)
    }

    /// - Parameters:
    ///   - windowBundleIDs: bundle ids of apps that have a normal window at Stop.
    ///   - appNames: display names by bundle id (falls back to the last part of the id).
    public static func analyze(_ recorded: [TimedStep], windowBundleIDs: Set<String>,
                               appNames: [String: String] = [:]) -> RecordingAnalysis {
        let steps = recorded.filter { !isWindowChrome($0.step) }
        var layout: [String] = []
        for e in steps {
            if case .launchApp(let b) = e.step, windowBundleIDs.contains(b), !layout.contains(b) { layout.append(b) }
        }

        // Group by app: a step with a known app starts a new group when it differs from the current one.
        var groups: [(bundleID: String?, steps: [TimedStep])] = []
        for e in steps {
            let app = bundleID(of: e.step)
            if let app, groups.last?.bundleID != app { groups.append((app, [])) }
            else if groups.isEmpty { groups.append((nil, [])) }
            groups[groups.count - 1].steps.append(e)
        }

        var actions: [DetectedAction] = []
        for group in groups {
            let kept = group.steps.filter { e in
                if case .launchApp(let b) = e.step, layout.contains(b) { return false }
                return true
            }
            guard !kept.isEmpty else { continue }
            actions.append(DetectedAction(name: name(for: kept, bundleID: group.bundleID, appNames: appNames),
                                          bundleID: group.bundleID, steps: kept))
        }
        return RecordingAnalysis(layoutBundleIDs: layout, actions: actions)
    }

    /// Clicks on close / minimize / zoom / full-screen buttons and on the title bar or toolbar background.
    static func isWindowChrome(_ step: ActionStep) -> Bool {
        guard case .press(let locator, _) = step.unwrapped, let last = locator.path.last else { return false }
        if let sub = last.subrole, ActionRecorder.chromeSubroles.contains(sub) { return true }
        return last.role == "AXToolbar" && (last.title ?? "").isEmpty && last.identifier == nil
    }

    static func bundleID(of step: ActionStep) -> String? {
        switch step.unwrapped {
        case .launchApp(let b): return b
        case .press(let l, _): return l.bundleID.isEmpty ? nil : l.bundleID
        case .menu(let b, _): return b.isEmpty ? nil : b
        case .typeText(_, let into): return into.flatMap { $0.bundleID.isEmpty ? nil : $0.bundleID }
        case .waitFor(let l, _, _): return l.bundleID.isEmpty ? nil : l.bundleID
        default: return nil
        }
    }

    /// "Streisand: press Connected" from the first meaningful step.
    static func name(for steps: [TimedStep], bundleID: String?, appNames: [String: String]) -> String {
        let app = bundleID.map { appNames[$0] ?? String($0.split(separator: ".").last ?? Substring($0)) }
        let list = steps.map(\.step)
        var what: String?
        for (i, step) in list.enumerated() {
            switch step.unwrapped {
            case .press(let l, _):
                what = "press " + label(of: l)
            case .menu(_, let path):
                what = "choose " + (path.last ?? "menu item")
            case .typeText:
                var enter = false
                if i + 1 < list.count, case .key(let k) = list[i + 1].unwrapped, k == "return" { enter = true }
                what = enter ? "type command" : "type text"
            case .key(let k): what = "press " + k
            case .shell: what = "run command"
            case .openURL: what = "open link"
            case .runShortcut(let n): what = "run " + n
            case .waitFor(let l, _, _): what = "wait for " + label(of: l)
            case .launchApp, .delay, .optional: continue
            }
            break
        }
        if what == nil, list.contains(where: { if case .launchApp = $0.unwrapped { return true } else { return false } }) {
            what = "open app"
        }
        let text = what ?? "actions"
        guard let app else { return text.prefix(1).uppercased() + text.dropFirst() }
        return "\(app): \(text)"
    }

    private static func label(of locator: ElementLocator) -> String {
        guard let m = locator.path.last else { return "button" }
        for text in [m.title, m.description, m.identifier] {
            if let text, !text.isEmpty { return text }
        }
        return m.role.replacingOccurrences(of: "AX", with: "").lowercased()
    }
}
