import Foundation

/// Pure helpers that turn raw system facts into the optional fields of `VirtualLiveWindow`.
/// Kept free of AppKit and Accessibility calls so the matching rules can be tested directly.
public enum LiveWindowInfo {
    /// Minimized flag per CGWindowID, from the windows Accessibility lists for one process.
    /// Entries without a readable CGWindowID cannot be matched, so they are skipped.
    /// If the same id appears twice, the first entry wins.
    public static func minimizedByID(_ entries: [(windowID: UInt32?, isMinimized: Bool)]) -> [UInt32: Bool] {
        var result: [UInt32: Bool] = [:]
        for entry in entries {
            guard let id = entry.windowID, result[id] == nil else { continue }
            result[id] = entry.isMinimized
        }
        return result
    }

    /// Minimized flag for one window; false when the window was not matched (the safe default).
    public static func isMinimized(windowID: UInt32, in minimized: [UInt32: Bool]) -> Bool {
        minimized[windowID] ?? false
    }
}
