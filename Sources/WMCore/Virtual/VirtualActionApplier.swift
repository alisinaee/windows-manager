import Foundation
import CoreGraphics

/// Carries out the unhide / restore steps of a recovery or reassert plan through the system backend.
/// `hideWindow` steps are not carried out here (parking needs the switcher's bookkeeping); they are counted as skipped.
public struct VirtualApplyReport: Equatable, Sendable {
    public var unhiddenApps: [Int32] = []
    public var restoredWindows: [UInt32] = []
    public var failures: [String] = []
    public var skippedHides = 0
}

public enum VirtualActionApplier {
    public static func apply(_ actions: [VirtualAction], system: WorkspaceSystem, tolerance: CGFloat = 2) -> VirtualApplyReport {
        var report = VirtualApplyReport()
        for action in actions {
            switch action {
            case .unhideApp(let pid):
                if system.unhideApp(pid: pid) { report.unhiddenApps.append(pid) }
                else { report.failures.append("App with pid \(pid) would not unhide.") }
            case .restoreFrame(let windowID, let pid, let frame):
                func back() -> Bool {
                    guard let f = system.frame(ofWindow: windowID, pid: pid) else { return false }
                    return abs(f.minX - frame.minX) <= tolerance && abs(f.minY - frame.minY) <= tolerance
                        && abs(f.width - frame.width) <= tolerance && abs(f.height - frame.height) <= tolerance
                }
                system.setPosition(frame.origin, ofWindow: windowID, pid: pid)
                if !back() { system.setFrame(frame, ofWindow: windowID, pid: pid) }
                if back() { report.restoredWindows.append(windowID) }
                else { report.failures.append("Window \(windowID) did not return to its frame.") }
            case .hideWindow:
                report.skippedHides += 1
            }
        }
        return report
    }
}
