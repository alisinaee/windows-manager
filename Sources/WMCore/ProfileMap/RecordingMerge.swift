import Foundation

// Merging the windows found by smart recording into a profile draft: missing monitors and Desktops are added
// instead of leaving windows out.

public struct RecordingMergeResult: Equatable, Sendable {
    public var added: Int = 0
    /// Names of the apps added as windows are in the profile; `skipped` lists windows that cannot be planned.
    public var skipped: [String] = []
    public init() {}

    /// "Skipped Safari (full screen), Mail (minimized)", or nil when nothing was skipped.
    public var note: String? { skipped.isEmpty ? nil : "Skipped " + skipped.joined(separator: ", ") }
}

extension ProfileDraftEditor {
    /// Adds a monitor with one empty Desktop. No-op when the draft already has it.
    public mutating func addDisplay(_ display: DisplayIdentity) throws {
        guard !profile.displays.contains(where: { $0.uuid == display.uuid }) else { return }
        var copy = profile
        copy.displays.append(display)
        copy.spaces.append(SpaceSnapshot(displayUUID: display.uuid, position: 0, kind: .desktop, desktopNumber: 1))
        copy.monitorSetKey = DisplayMap.monitorSetKey(copy.displays)
        self = ProfileDraftEditor(copy)
    }

    /// Adds `windows` as planned windows. A window's monitor is taken from `displays` when the draft lacks it, and
    /// Desktops are added up to the window's number. Full-screen, minimized and all-Desktops windows are skipped
    /// (reported in the result). Throws on an edit failure; the caller applies this inside one undoable edit.
    public mutating func mergeRecording(windows: [WindowSnapshot], displays: [DisplayIdentity]) throws -> RecordingMergeResult {
        var result = RecordingMergeResult()
        for w in windows {
            let reason: String?
            if w.isMinimized { reason = "minimized" }
            else if w.isFullScreen { reason = "full screen" }
            else {
                switch w.placement {
                case .desktop: reason = nil
                case .fullScreen: reason = "full screen"
                case .allDesktops: reason = "all Desktops"
                case .unknown: reason = "unknown Desktop"
                }
            }
            if let reason { result.skipped.append("\(w.app.name) (\(reason))"); continue }
            guard case .desktop(let n) = w.placement else { continue }
            if !profile.displays.contains(where: { $0.uuid == w.displayUUID }) {
                guard let live = displays.first(where: { $0.uuid == w.displayUUID }) else {
                    result.skipped.append("\(w.app.name) (monitor not connected)")
                    continue
                }
                try addDisplay(live)
            }
            while profile.spaces.filter({ $0.displayUUID == w.displayUUID && $0.kind == .desktop }).count < max(n, 1) {
                try addDesktop(onDisplay: w.displayUUID)
            }
            try addPlannedWindow(app: w.app, onDisplay: w.displayUUID, desktop: n, frame: w.frame)
            result.added += 1
        }
        return result
    }
}
