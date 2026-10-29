import Foundation

/// Bounded list of the newest log lines shown in the Debug panel's live log.
public enum DebugLogTail {
    public static let limit = 200

    /// Appends `line` and keeps only the newest `limit` lines. Blank lines are ignored.
    public static func append(_ line: String, to lines: [String], limit: Int = DebugLogTail.limit) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lines }
        var next = lines
        next.append(trimmed)
        if next.count > limit { next.removeFirst(next.count - limit) }
        return next
    }
}
