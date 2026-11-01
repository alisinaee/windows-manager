import SwiftUI
import WMCore

/// Profile Studio shell: unified window toolbar, a NavigationSplitView (profile sidebar | map) and a Details inspector.
struct ProfileStudioView: View {
    @ObservedObject var model: ProfileStudioModel
    /// The inspector page lives here, above the View / Edit switch, so it survives switching modes.
    @State private var inspectorTab = ProfileStudioModel.uxInspectorTab ?? .inspector
    @State private var isAccessibilityBannerDismissed = false

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Loading profiles…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                Banner(tone: .danger, title: "Could not load profiles", message: message,
                       actionLabel: "Try Again", action: { model.reload() })
                    .frame(maxWidth: 480)
                    .padding(Spacing.l)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded, .empty:
                splitView
            }
        }
        // No .frame(minWidth:) here or on any split column: the window's contentMinSize already sets the floor. A
        // SwiftUI min size on a column root is re-reported by every split-view child and, with the inspector open, loops.
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(windowSubtitle)
        .tint(Palette.accent)
        .onAppear { model.reload() }
    }

    /// Capture date only; the unsaved state is the dot next to the name in Edit mode.
    private var windowSubtitle: String {
        guard let row = model.selectedRow else { return "" }
        return row.capturedAt.formatted(date: .abbreviated, time: .omitted)
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { model.isSidebarShown ? .all : .detailOnly },
                set: { model.setSidebar(shown: $0 != .detailOnly) })
    }

    /// The draft behind the review sheet; nil closes it.
    private var reviewDraft: Binding<ProfileBuilderModel?> {
        Binding(get: { model.isReviewCapturePresented ? model.builder : nil },
                set: { if $0 == nil { model.isReviewCapturePresented = false } })
    }

    /// The draft behind the save sheet; nil closes it.
    private var saveDraft: Binding<ProfileBuilderModel?> {
        Binding(get: { model.isSaveSheetPresented ? model.builder : nil },
                set: { if $0 == nil { model.isSaveSheetPresented = false } })
    }

    // Column minimums (sidebar 200 + inspector 280) stay below the window minimum; the map column has none.
    private var splitView: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            StudioSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            StudioDetail(model: model, inspectorTab: $inspectorTab,
                         isAccessibilityBannerDismissed: $isAccessibilityBannerDismissed)
        }
        .toolbar { StudioToolbar(model: model) }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { model.contentWidthChanged($0) }
        .sheet(isPresented: $model.isCopyPickerPresented) {
            StudioCopyPickerSheet(profiles: model.rows, onCopy: { model.beginCopy(of: $0) },
                                  onCancel: { model.isCopyPickerPresented = false })
                .sheetFadeIn()
        }
        .sheet(item: reviewDraft) { builder in
            CaptureReviewPanel(capture: model.capture, builder: builder, onDone: { model.isReviewCapturePresented = false })
                .sheetFadeIn()
        }
        .sheet(item: saveDraft) { builder in
            StudioSaveSheet(builder: builder, onSaved: { model.didSave($0) }, onCancel: { model.cancelSave() })
                .sheetFadeIn()
        }
        .confirmationDialog("You have unsaved changes", isPresented: $model.isSwitchConfirmPresented, titleVisibility: .visible) {
            Button("Save…") { model.confirmSwitch(save: true) }
            Button("Discard Changes", role: .destructive) { model.confirmSwitch(save: false) }
            Button("Cancel", role: .cancel) { model.cancelSwitch() }
        } message: {
            Text("Switching profiles throws away what you changed since the last save.")
        }
        .confirmationDialog("You have unsaved changes", isPresented: $model.isLeaveConfirmPresented, titleVisibility: .visible) {
            Button("Save…") { model.saveThen { model.leaveEdit() } }
            Button("Discard Changes", role: .destructive) { model.leaveEdit() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Leaving Edit mode throws away what you changed since the last save.")
        }
        .confirmationDialog("Delete this profile?", item: $model.deleteTarget, titleVisibility: .visible) { row in
            Button("Delete \u{201C}\(row.name)\u{201D}", role: .destructive) { model.deleteTarget = row; model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.deleteTarget = nil }
        } message: { _ in
            Text("It moves to the Trash folder. You can undo right after.")
        }
        .alert("Rename Profile", item: $model.renameTarget) { row in
            TextField("Name", text: $model.renameText)
            Button("Rename") { model.renameTarget = row; model.commitRename() }
            Button("Cancel", role: .cancel) { model.renameTarget = nil }
        }
    }
}
