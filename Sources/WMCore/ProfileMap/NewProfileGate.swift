import Foundation

/// Whether a "New profile" press can start something now (P6.131). A press that cannot start must say why:
/// a disabled or silently ignored button reads as "the add profile button is not working".
public enum NewProfileGate {
    /// The message shown next to the button when a press is refused, or nil when it can start.
    public static func refusal(isEditing: Bool, hasUnsavedChanges: Bool) -> String? {
        guard isEditing else { return nil }
        return hasUnsavedChanges
            ? "A profile is being edited with unsaved changes. Save or Cancel it first, then add a new one."
            : "A profile is open in Edit mode. Click Cancel to leave it, then add a new one."
    }
}
