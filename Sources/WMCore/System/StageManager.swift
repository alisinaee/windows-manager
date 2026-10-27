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
    ///  0. A strip thumbnail (`isStripThumbnail`) is the strip's picture of a real window: certainly in the strip.
    ///  1. A window that is minimized, full-screen or whose app is hidden is excluded (unknown).
    ///  2. On screen -> active, whatever Space it is on: a window on screen is visible, so the frame fallback below
    ///     does not apply to it.
    ///  3. Not on screen although it is on the current Space (and not minimized or hidden) -> in the strip or in
    ///     another stage, but only a guess.
    ///  4. Fallback: a frame almost entirely off every monitor (older macOS versions park windows there).
    ///  5. Anything else (other Space, no on-screen flag) -> unknown.
    /// Stage Manager keeps the original frames of strip windows, so the frame alone is not enough.
    public static func classify(_ window: LiveWindow, displays: [DisplayIdentity]) -> Verdict {
        if window.isStripThumbnail { return Verdict(state: .strip, isHeuristic: false) }
        if window.isMinimized || window.isFullScreen || window.isAppHidden { return Verdict(state: .unknown, isHeuristic: false) }
        if window.isOnScreen == true { return Verdict(state: .active, isHeuristic: false) }
        if window.isOnCurrentSpace, window.isOnScreen == false { return Verdict(state: .strip, isHeuristic: true) }
        if isParkedOffscreen(window.frame, displays: displays) { return Verdict(state: .strip, isHeuristic: true) }
        return Verdict(state: .unknown, isHeuristic: false)
    }

    /// How far apart two thumbnails may sit (along the strip) and still belong to the same stage, in points.
    static let stageGapLimit: CGFloat = 30

    /// Records the Stage Manager state in `scan` and, when it is on, marks the windows that sit in the strip or
    /// in another stage (`LiveWindow.isInStageStrip`) and fills `LiveWindow.stage`. Minimized and full-screen
    /// windows are never marked.
    ///
    /// A strip thumbnail (`LiveWindow.isStripThumbnail`) is the real window drawn small, with the same window id,
    /// so it stays in `windows` as a strip window. Thumbnails are grouped into stages by position
    /// (`clusterThumbnails`) and those groups are certain. Other strip windows (off screen on the current Space,
    /// or parked off every monitor) are grouped by app, as a guess, and are flagged heuristic. Groups are numbered
    /// 1... with the thumbnail stages first, top to bottom. Active windows are group 0.
    public static func annotate(_ scan: WorkspaceScan, provider: StageManagerProvider = .live) -> WorkspaceScan {
        var result = scan
        let enabled = provider.isEnabled()
        result.stageManagerOn = enabled
        guard enabled == true else { return result }
        var groupOfThumbnail: [Int: Int] = [:]
        for (position, cluster) in clusterThumbnails(result.windows, displays: scan.displays).enumerated() {
            for index in cluster { groupOfThumbnail[index] = position + 1 }
        }
        var nextGroup = (groupOfThumbnail.values.max() ?? 0) + 1
        var groupOfApp: [String: Int] = [:]
        for index in result.windows.indices {
            let window = result.windows[index]
            let verdict = classify(window, displays: scan.displays)
            switch verdict.state {
            case .unknown: continue
            case .active:
                result.windows[index].stage = SavedStage(group: 0, isActive: true, isHeuristic: verdict.isHeuristic)
            case .strip:
                let group: Int
                if window.isStripThumbnail {
                    group = groupOfThumbnail[index] ?? 1
                } else {
                    let key = appKey(window)
                    if let known = groupOfApp[key] {
                        group = known
                    } else {
                        group = nextGroup
                        nextGroup += 1
                        groupOfApp[key] = group
                    }
                }
                result.windows[index].isInStageStrip = true
                result.windows[index].stage = SavedStage(group: group, isActive: false, isHeuristic: verdict.isHeuristic)
            }
        }
        return result
    }

    /// Groups the strip thumbnails of `windows` into stages, by index into `windows`. Two thumbnails on the same
    /// display share a stage when their rectangles overlap or sit less than `stageGapLimit` apart along the strip:
    /// vertically, or horizontally when the strip is on the right edge of its display. Thumbnails on different
    /// displays never share a stage. Stages come back top to bottom. Uses the window-server bounds, which the
    /// thumbnail keeps (`serverBounds`), and falls back to `frame`.
    static func clusterThumbnails(_ windows: [LiveWindow], displays: [DisplayIdentity]) -> [[Int]] {
        let items = windows.indices.filter { windows[$0].isStripThumbnail }.map { index -> (index: Int, rect: CGRect, display: Int?) in
            let rect = windows[index].serverBounds ?? windows[index].frame
            let center = CGPoint(x: rect.midX, y: rect.midY)
            return (index, rect, displays.firstIndex { $0.frame.contains(center) })
        }
        var parent = Array(items.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for a in items.indices {
            for b in items.indices where b > a {
                guard let display = items[a].display, items[b].display == display else { continue }
                let first = items[a].rect, second = items[b].rect
                let onRightEdge = first.midX > displays[display].frame.midX
                let gap = onRightEdge
                    ? max(first.minX, second.minX) - min(first.maxX, second.maxX)
                    : max(first.minY, second.minY) - min(first.maxY, second.maxY)
                if gap < stageGapLimit {
                    let (rootA, rootB) = (root(a), root(b))
                    parent[rootB] = rootA
                }
            }
        }
        var clusters: [Int: (top: CGFloat, members: [Int])] = [:]
        for (position, item) in items.enumerated() {
            let key = root(position)
            var cluster = clusters[key] ?? (top: .infinity, members: [])
            cluster.top = min(cluster.top, item.rect.minY)
            cluster.members.append(item.index)
            clusters[key] = cluster
        }
        return clusters.values.sorted { $0.top < $1.top }.map(\.members)
    }

    /// The key that is the same for all windows of one app: the lowercased bundle id, else the lowercased name.
    private static func appKey(_ window: LiveWindow) -> String {
        window.app.bundleID?.lowercased() ?? window.app.name.lowercased()
    }
}
