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

    /// Records the Stage Manager state in `scan` and, when it is on, marks the windows that sit in the strip or
    /// in another stage (`LiveWindow.isInStageStrip`). Minimized and full-screen windows are never marked.
    public static func annotate(_ scan: WorkspaceScan, provider: StageManagerProvider = .live) -> WorkspaceScan {
        var result = scan
        let enabled = provider.isEnabled()
        result.stageManagerOn = enabled
        guard enabled == true else { return result }
        for index in result.windows.indices {
            let window = result.windows[index]
            if window.isMinimized || window.isFullScreen { continue }
            if isParkedOffscreen(window.frame, displays: scan.displays) { result.windows[index].isInStageStrip = true }
        }
        return result
    }
}
