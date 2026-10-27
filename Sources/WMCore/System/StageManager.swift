import CoreGraphics
import Foundation

/// Stage Manager awareness (P3.8). Windows Manager works with Stage Manager on or off and never asks anyone to
/// change it. The state is read through a small injectable provider so the logic can be tested.
public struct StageManagerProvider: Sendable {
    /// True/false when known, nil when it cannot be read.
    public var isEnabled: @Sendable () -> Bool?

    public init(isEnabled: @escaping @Sendable () -> Bool?) { self.isEnabled = isEnabled }

    /// A fixed answer, for tests.
    public static func fixed(_ value: Bool?) -> StageManagerProvider { StageManagerProvider { value } }

    /// Reads `com.apple.WindowManager GloballyEnabled`. A missing key means off (the macOS default).
    public static let live = StageManagerProvider {
        let value = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString)
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}

public enum StageManager {
    /// A window with less than this share of its area on any monitor counts as parked in the Stage Manager strip
    /// or in another stage (it cannot be reached or moved there).
    static let minimumVisibleShare: CGFloat = 0.1

    /// True when almost none of `frame` lies on any of the displays.
    public static func isParkedOffscreen(_ frame: CGRect, displays: [DisplayIdentity]) -> Bool {
        let area = frame.width * frame.height
        guard area > 0, !displays.isEmpty else { return false }
        let visible = displays.map { display -> CGFloat in
            let overlap = frame.intersection(display.frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }.max() ?? 0
        return visible / area < minimumVisibleShare
    }

    /// What Stage Manager state a window is in.
    public enum State: Equatable, Sendable { case active, strip, unknown }

    /// The result of `classify`: the state, and whether it is only a guess.
    public struct Verdict: Equatable, Sendable {
        public var state: State
        public var isHeuristic: Bool
    }

    /// Works out where one window sits. macOS has no public Stage Manager API, so this reads side effects:
    ///  1. Primary: a window that is NOT on screen (`kCGWindowIsOnscreen` false) although it is not minimized, its
    ///     app is not hidden and it is on the current Space can only be in the strip or in another stage.
    ///  2. Fallback: a frame almost entirely off every monitor (older macOS versions park windows there).
    ///  3. On screen -> active. Anything else (other Space, hidden app, no on-screen flag) -> unknown.
    /// Stage Manager keeps the original frames of strip windows, so the frame alone is not enough.
    public static func classify(_ window: LiveWindow, displays: [DisplayIdentity]) -> Verdict {
        if window.isMinimized || window.isFullScreen || window.isAppHidden { return Verdict(state: .unknown, isHeuristic: false) }
        if window.isOnCurrentSpace, window.isOnScreen == false { return Verdict(state: .strip, isHeuristic: false) }
        if isParkedOffscreen(window.frame, displays: displays) { return Verdict(state: .strip, isHeuristic: true) }
        if window.isOnCurrentSpace, window.isOnScreen == true { return Verdict(state: .active, isHeuristic: false) }
        return Verdict(state: .unknown, isHeuristic: false)
    }

    /// Records the Stage Manager state in `scan` and, when it is on, marks the windows that sit in the strip or
    /// in another stage (`LiveWindow.isInStageStrip`) and fills `LiveWindow.stage`. Minimized and full-screen
    /// windows are never marked.
    ///
    /// Limits: strip windows are grouped by app (Stage Manager's default, one stage per app), numbered 1... in scan
    /// order, and always flagged heuristic, because stages the user assembled by hand cannot be told apart from
    /// the API side. Active windows are group 0.
    public static func annotate(_ scan: WorkspaceScan, provider: StageManagerProvider = .live) -> WorkspaceScan {
        var result = scan
        let enabled = provider.isEnabled()
        result.stageManagerOn = enabled
        guard enabled == true else { return result }
        var groupOfApp: [String: Int] = [:]
        for index in result.windows.indices {
            let window = result.windows[index]
            let verdict = classify(window, displays: scan.displays)
            switch verdict.state {
            case .unknown: continue
            case .active:
                result.windows[index].stage = SavedStage(group: 0, isActive: true, isHeuristic: verdict.isHeuristic)
            case .strip:
                let key = window.app.bundleID?.lowercased() ?? window.app.name.lowercased()
                let group = groupOfApp[key] ?? groupOfApp.count + 1
                groupOfApp[key] = group
                result.windows[index].isInStageStrip = true
                result.windows[index].stage = SavedStage(group: group, isActive: false, isHeuristic: true)
            }
        }
        return result
    }
}
