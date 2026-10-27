import CoreGraphics
import Foundation

/// Plain-text dump of one scan, one line per window, for diagnosing Stage Manager capture. It shows the
/// window-server bounds next to the Accessibility frame, so a window that is in the strip or on another
/// Space can be told apart from one in the active stage. Pure: no system calls, it only formats the scan.
public enum WindowDump {
    /// A header line, then one `win ...` line per window in the scan's order.
    public static func lines(for scan: WorkspaceScan) -> [String] {
        var out = ["stageManagerOn=\(flag(scan.stageManagerOn)) windows=\(scan.windows.count)"]
        for window in scan.windows { out.append(line(for: window)) }
        return out
    }

    static func line(for window: LiveWindow) -> String {
        var parts = ["win"]
        parts.append("id=\(window.windowID)")
        parts.append("app=\(window.app.name)")
        // LiveWindow carries no CG layer, so it is always "-" here.
        parts.append("layer=-")
        parts.append("onscreen=\(flag(window.isOnScreen))")
        parts.append("bounds=" + (window.serverBounds.map(rect) ?? "-"))
        parts.append("ax=" + rect(window.frame))
        parts.append("display=" + (window.displayUUID.map { String($0.prefix(8)) } ?? "-"))
        parts.append("currentSpace=\(window.isOnCurrentSpace)")
        parts.append("stage=\(stageName(window))")
        parts.append("group=" + (window.stage.map { String($0.group) } ?? "-"))
        parts.append("heuristic=" + (window.stage.map { String($0.isHeuristic) } ?? "-"))
        parts.append("thumb=\(window.isStripThumbnail)")
        return parts.joined(separator: " ")
    }

    private static func stageName(_ window: LiveWindow) -> String {
        guard let stage = window.stage else { return "unknown" }
        return stage.isActive ? "active" : "strip"
    }

    private static func flag(_ value: Bool?) -> String {
        value.map { String($0) } ?? "nil"
    }

    /// `1200x800@100,200`, whole points like the capture summary.
    private static func rect(_ frame: CGRect) -> String {
        "\(Int(frame.width))x\(Int(frame.height))@\(Int(frame.minX)),\(Int(frame.minY))"
    }
}
