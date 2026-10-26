import Foundation

/// The outcome of looking a profile up by name.
public enum ProfileResolution: Equatable, Sendable {
    case found(UUID)
    /// Several profiles match the name, so none is run: the caller must ask for a unique name.
    case ambiguous
    case none
}

/// Finds a profile by the name a URL, command line or user typed. Names are not unique (capture and rename
/// do not enforce it), so the rule must be deterministic:
/// an exact match wins when it is unique; otherwise a case-insensitive match wins when it is unique;
/// any other count (two or more) is ambiguous and nothing runs.
public enum ProfileResolver {
    public static func resolve(_ name: String, in profiles: [ProfileSummary]) -> ProfileResolution {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return .none }

        let exact = profiles.filter { $0.name == wanted }
        if exact.count == 1, let only = exact.first { return .found(only.id) }
        if exact.count > 1 { return .ambiguous }

        let loose = profiles.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame
        }
        if loose.count == 1, let only = loose.first { return .found(only.id) }
        return loose.isEmpty ? .none : .ambiguous
    }
}
