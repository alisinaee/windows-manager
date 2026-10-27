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

    /// Largest width and height of a strip thumbnail, in points.
    static let thumbnailMaxSide: CGFloat = 200
    /// Largest share of its monitor a strip thumbnail covers.
    static let thumbnailMaxShare: CGFloat = 0.03
    /// How close a thumbnail's left or right edge must be to the monitor's edge, in points.
    static let thumbnailEdgeTolerance: CGFloat = 40

    /// True when a window's own bounds look like the Stage Manager strip thumbnail of a window: on screen, small
    /// (both sides <= 200 pt, under 3% of its monitor), and with its left or right edge within 40 pt of the monitor
    /// edge. `bounds` must be the window server's bounds, not an Accessibility frame. Pure.
    public static func isStripThumbnailShape(_ bounds: CGRect, isOnScreen: Bool?, displays: [DisplayIdentity]) -> Bool {
        guard isOnScreen == true, bounds.width > 0, bounds.height > 0,
              bounds.width <= thumbnailMaxSide, bounds.height <= thumbnailMaxSide else { return false }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let display = displays.first(where: { $0.frame.contains(center) }) else { return false }
        guard bounds.width * bounds.height < thumbnailMaxShare * display.frame.width * display.frame.height else { return false }
        let nearLeft = abs(bounds.minX - display.frame.minX) <= thumbnailEdgeTolerance
        let nearRight = abs(bounds.maxX - display.frame.maxX) <= thumbnailEdgeTolerance
        return nearLeft || nearRight
    }

    /// Works out where one window sits. macOS has no public Stage Manager API, so this reads side effects:
    ///  0. A strip thumbnail (`isStripThumbnail`) is never active: it is the strip's picture of a real window.
    ///  1. Primary: a window that is NOT on screen (`kCGWindowIsOnscreen` false) although it is not minimized, its
    ///     app is not hidden and it is on the current Space can only be in the strip or in another stage.
    ///  2. On screen -> active. A window on screen is visible, so the frame fallback below does not apply to it.
    ///  3. Fallback: a frame almost entirely off every monitor (older macOS versions park windows there).
    ///  4. Anything else (other Space, hidden app, no on-screen flag) -> unknown.
    /// Stage Manager keeps the original frames of strip windows, so the frame alone is not enough.
    /// `appHasThumbnail` says the app has a strip thumbnail: its real windows that are not on screen are strip windows
    /// (`annotate` passes it).
    public static func classify(_ window: LiveWindow, displays: [DisplayIdentity], appHasThumbnail: Bool = false) -> Verdict {
        if window.isStripThumbnail { return Verdict(state: .strip, isHeuristic: true) }
        if window.isMinimized || window.isFullScreen || window.isAppHidden { return Verdict(state: .unknown, isHeuristic: false) }
        if window.isOnCurrentSpace, window.isOnScreen == false { return Verdict(state: .strip, isHeuristic: false) }
        if window.isOnCurrentSpace, window.isOnScreen == true { return Verdict(state: .active, isHeuristic: false) }
        if window.isOnCurrentSpace, appHasThumbnail { return Verdict(state: .strip, isHeuristic: false) }
        if isParkedOffscreen(window.frame, displays: displays) { return Verdict(state: .strip, isHeuristic: true) }
        return Verdict(state: .unknown, isHeuristic: false)
    }

    /// Records the Stage Manager state in `scan` and, when it is on, marks the windows that sit in the strip or
    /// in another stage (`LiveWindow.isInStageStrip`) and fills `LiveWindow.stage`. Minimized and full-screen
    /// windows are never marked.
    ///
    /// Strip thumbnails (`LiveWindow.isStripThumbnail`, set by the scanner) are not windows of their own: when the
    /// app has a real window that is not on screen, the thumbnail is dropped from `windows` and that window is the
    /// strip window. An app whose only strip picture is the thumbnail keeps it, as a strip window.
    ///
    /// Limits: strip windows are grouped by app (Stage Manager's default, one stage per app), numbered 1... in scan
    /// order, and always flagged heuristic, because stages the user assembled by hand cannot be told apart from
    /// the API side. Active windows are group 0.
    public static func annotate(_ scan: WorkspaceScan, provider: StageManagerProvider = .live) -> WorkspaceScan {
        var result = scan
        let enabled = provider.isEnabled()
        result.stageManagerOn = enabled
        guard enabled == true else { return result }
        let thumbnailKeys = Set(scan.windows.filter(\.isStripThumbnail).map { appKey($0) })
        var groupOfApp: [String: Int] = [:]
        var dropped = Set<Int>()
        for index in result.windows.indices {
            let window = result.windows[index]
            let key = appKey(window)
            if window.isStripThumbnail, scan.windows.contains(where: { hasRealStripWindow($0, key: key) }) {
                dropped.insert(index)
                continue
            }
            let verdict = classify(window, displays: scan.displays, appHasThumbnail: thumbnailKeys.contains(key))
            switch verdict.state {
            case .unknown: continue
            case .active:
                result.windows[index].stage = SavedStage(group: 0, isActive: true, isHeuristic: verdict.isHeuristic)
            case .strip:
                let group = groupOfApp[key] ?? groupOfApp.count + 1
                groupOfApp[key] = group
                result.windows[index].isInStageStrip = true
                // Only a strip window confirmed by the app's thumbnail is certain; the rest stay heuristic.
                let confirmed = thumbnailKeys.contains(key) && !window.isStripThumbnail && verdict.isHeuristic == false
                result.windows[index].stage = SavedStage(group: group, isActive: false, isHeuristic: !confirmed)
            }
        }
        result.windows = result.windows.indices.filter { !dropped.contains($0) }.map { result.windows[$0] }
        return result
    }

    /// The key that is the same for all windows of one app: the lowercased bundle id, else the lowercased name.
    private static func appKey(_ window: LiveWindow) -> String {
        window.app.bundleID?.lowercased() ?? window.app.name.lowercased()
    }

    /// A real window of the app that is not a thumbnail and is not on screen (so it is the one the strip stands for).
    private static func hasRealStripWindow(_ window: LiveWindow, key: String) -> Bool {
        !window.isStripThumbnail && appKey(window) == key && window.isOnScreen != true
            && !window.isMinimized && !window.isAppHidden
    }
}
