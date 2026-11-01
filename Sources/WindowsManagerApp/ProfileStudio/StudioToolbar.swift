import SwiftUI
import WMCore

/// The unified window toolbar. Centre: View / Edit. View mode: [Compare, Check Now, Preview], Run, More.
/// Edit mode: Cancel, [Undo, Redo], the problems button, More, Save. The Details toggle is last in both.
/// Undo / Redo / Save shortcuts live in the app menu. Appearance lives in Settings.
struct StudioToolbar: ToolbarContent {
    @ObservedObject var model: ProfileStudioModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            StudioModePicker(model: model)
        }
        .sharedBackgroundVisibility(.hidden)
        if model.mode == .edit, let builder = model.builder {
            editItems(builder)
        } else if let row = model.selectedRow {
            viewItems(row)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { model.isInspectorShown.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                .help(model.isInspectorShown ? "Hide the Details inspector" : "Show the Details inspector")
                .accessibilityLabel(model.isInspectorShown ? "Hide details" : "Show details")
        }
        .sharedBackgroundVisibility(.hidden)
    }

    @ToolbarContentBuilder
    private func editItems(_ builder: ProfileBuilderModel) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { model.requestLeaveEdit() }
                .foregroundStyle(.primary)
                .help("Leave Edit mode. With unsaved changes you are asked to save, discard them, or keep editing.")
                .accessibilityLabel("Cancel editing")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button { builder.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                    .help("Undo the last change (Cmd+Z)")
                    .accessibilityLabel("Undo")
                Button { builder.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!model.canRedo)
                    .help("Redo (Shift+Cmd+Z)")
                    .accessibilityLabel("Redo")
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            StudioProblemBadge(builder: builder)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            StudioMoreMenu(model: model, builder: builder)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .confirmationAction) {
            // Dim until there is something to save (a brand-new profile can always be saved).
            Button("Save") { model.saveThen(nil) }
                .buttonStyle(.glassProminent).tint(Palette.accentStrong)
                .disabled(builder.blocksSaving)
                .help(builder.blocksSaving ? "Fix the problems marked in red first" : "Save the profile (Cmd+S)")
                .accessibilityLabel("Save profile")
        }
        .sharedBackgroundVisibility(.hidden)
    }

    @ToolbarContentBuilder
    private func viewItems(_ row: ProfileStudioRow) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Toggle(isOn: Binding(get: { model.isCompareOn }, set: { model.setCompare($0) })) {
                    Label("Compare", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Compare: check this profile against the windows on your Mac now and mark what is missing or moved (Cmd+L). Only scans: nothing is moved.")
                .accessibilityLabel("Compare with your Mac")
                Button { model.setCompare(true); model.refreshCompare() } label: {
                    Label("Check Now", systemImage: "arrow.clockwise")
                }
                .disabled(model.isComparing)
                .help("Check Now: compare this profile with your Mac again (Cmd+R)")
                .accessibilityLabel("Check now")
                Button { DebugLog.log("studio", "preview restore opened: \(row.name)"); model.previewScope = .whole; model.isPreviewPresented = true } label: { Label("Preview", systemImage: "list.bullet.rectangle") }
                    .help("Preview restore: see what a restore would do, step by step (Shift+Cmd+P)")
                    .accessibilityLabel("Preview restore")
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            if let app = AppState.current {
                StudioRunControl(app: app, model: model, profileID: row.id, profileName: row.name, iconOnly: false,
                                 showEditor: $model.isShortcutEditorPresented)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            StudioMoreMenu(model: model, builder: nil)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}
