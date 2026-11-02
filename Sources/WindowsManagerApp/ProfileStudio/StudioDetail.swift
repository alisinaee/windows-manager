import SwiftUI
import WMCore

/// The detail column: banners on top, then the map (View), the draft (Edit) or an empty state.
struct StudioDetail: View {
    @ObservedObject var model: ProfileStudioModel
    @Binding var inspectorTab: StudioInspectorTab
    @Binding var isAccessibilityBannerDismissed: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let app = AppState.current {
                StudioAccessibilityBanner(app: app, isDismissed: $isAccessibilityBannerDismissed)
            }
            if let message = model.actionError {
                Banner(tone: .danger, title: "That did not work", message: message, onDismiss: { model.actionError = nil })
                    .padding(Spacing.s)
            }
            if let name = model.deletedName {
                Banner(tone: .info, title: "Deleted \u{201C}\(name)\u{201D}", actionLabel: "Undo",
                       action: { model.undoDelete() }, onDismiss: { model.clearDeleted() })
                    .padding(Spacing.s)
            }
            if model.mode == .edit, let builder = model.builder {
                if let draft = builder.recoveredDraft {
                    RecoveryBanner(draft: draft, isStale: builder.recoveredIsStale,
                                   restore: { builder.restoreRecovered() }, discard: { builder.discardRecovered() })
                }
            } else if let draft = model.viewRecovery {
                RecoveryBanner(draft: draft, isStale: model.viewRecoveryIsStale,
                               restore: { model.restoreViewRecovery() }, discard: { model.discardViewRecovery() })
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        if model.mode == .edit, let builder = model.builder {
            StudioEditDetail(model: model, builder: builder, inspectorTab: $inspectorTab)
                .id(ObjectIdentifier(builder))
        } else if let row = model.selectedRow {
            StudioMapHost(row: row, model: model, inspectorTab: $inspectorTab)
                .sheet(isPresented: $model.isPreviewPresented) {
                    RestorePreviewSheet(profileID: row.id, profileName: row.name, scope: model.previewScope) { model.isPreviewPresented = false }
                        .sheetFadeIn()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                    // The Studio window coming back to the front: refresh the comparison (never polls).
                    if (note.object as? NSWindow)?.isKeyWindow == true, !model.isPreviewPresented { model.refreshCompare() }
                }
        } else if model.rows.isEmpty {
            StudioNoProfiles(model: model)
        } else {
            ContentUnavailableView {
                Label("Select a Profile", systemImage: "rectangle.3.group")
            } description: {
                Text("Choose one on the left, or create a new one.")
            } actions: {
                Button { model.beginNewProfile() } label: { Label("New Profile", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(Palette.accentStrong).controlSize(.large)
                    .help("Start a new profile from the current workspace")
                    .accessibilityLabel("New profile")
            }
        }
    }
}
