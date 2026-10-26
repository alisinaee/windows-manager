import Foundation

// Merges a workspace switch's result into the user's latest edits before the model is saved (phase P6.12).
// A switch runs on a background queue from a snapshot of the model. While it runs, the user can rename,
// assign or create workspaces; those edits exist only in memory until the next save. The switch saves its
// own copy of the model, so the merge keeps the user's workspace list and takes only the switch's state:
// the active workspace id and the hidden-window records. Pure data, no system calls.

public enum WorkspaceModelMerge {
    /// The user's workspaces win, so edits made during a switch are kept. From the switch come the active
    /// workspace id and the hidden records. Records for workspaces that are no longer in the user's list
    /// are dropped, and so is an active id that points at a deleted workspace.
    public static func merge(userEdited: WorkspaceModel, switchResult: WorkspaceModel) -> WorkspaceModel {
        var merged = userEdited
        let liveIDs = Set(userEdited.workspaces.map(\.id))
        if let active = switchResult.activeWorkspaceID, liveIDs.contains(active) {
            merged.activeWorkspaceID = active
        } else {
            merged.activeWorkspaceID = nil
        }
        merged.hiddenRecords = switchResult.hiddenRecords.filter { record in
            guard let owner = record.workspaceID else { return true }
            return liveIDs.contains(owner)
        }
        return merged
    }
}
