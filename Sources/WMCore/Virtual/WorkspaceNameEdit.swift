import Foundation

/// The name a workspace name field commits to. The field edits a draft while the user types; this runs only
/// when the draft is committed (submit or focus loss), so spaces typed inside a name survive.
public enum WorkspaceNameEdit {
    /// The trimmed draft, or the current name when the draft is empty or only whitespace.
    public static func committedName(draft: String, current: String) -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? current : trimmed
    }
}
