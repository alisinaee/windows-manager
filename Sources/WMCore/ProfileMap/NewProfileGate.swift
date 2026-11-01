import Foundation

/// What a "New profile" press does (P1-8). It always starts something; the only question is whether to ask first.
public enum NewProfileGate {
    public enum Action: Equatable, Sendable {
        /// Start the draft now (View mode, or Edit with nothing to lose: Edit is left silently).
        case start
        /// Edit has unsaved changes: ask Save / Discard / Cancel before starting.
        case confirm
    }

    public static func action(isEditing: Bool, hasUnsavedChanges: Bool) -> Action {
        isEditing && hasUnsavedChanges ? .confirm : .start
    }
}
