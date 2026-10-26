import Foundation

/// Decides whether a dropped string may be assigned to a layout zone as an app's bundle id.
public enum BundleIDValidation {
    /// True when `candidate` looks like a reverse-DNS bundle id: letters, digits, `-` and `.` only,
    /// at least one dot, and no empty component (so no leading, trailing or doubled dots).
    public static func looksLikeBundleID(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.contains(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return candidate.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty }
    }

    /// True when a drop should be accepted: the string looks like a bundle id, or it is the
    /// bundle id of an app that is running right now.
    public static func accepts(_ candidate: String, runningBundleIDs: Set<String>) -> Bool {
        looksLikeBundleID(candidate) || runningBundleIDs.contains(candidate)
    }
}
