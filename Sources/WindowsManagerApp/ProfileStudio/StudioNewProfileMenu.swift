import SwiftUI

/// The sidebar's bottom bar: a "+" button that starts a profile from the current workspace; its menu has the other
/// starting points, and "Review Capture…" while a capture is behind the draft.
struct StudioNewProfileMenu: View {
    @ObservedObject var model: ProfileStudioModel
    @ObservedObject var capture: CaptureChoiceModel

    private var canReview: Bool { model.mode == .edit && capture.stage == .ready }

    var body: some View {
        HStack {
            Menu {
                Button("From Current Workspace") { model.beginNewProfile() }.help("Start a profile from the windows open now")
                Button("Blank on These Monitors") { model.beginBlankProfile() }.help("Start an empty profile on these monitors")
                Button("Copy of a Profile…") { model.requestCopyPicker() }.help("Start from a copy of a saved profile")
                if canReview {
                    Button("Review Capture…") { model.isReviewCapturePresented = true }.help("Untick the captured windows to leave out")
                }
            } label: {
                Label("New Profile", systemImage: "plus")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            } primaryAction: {
                model.beginNewProfile()
            }
            // The sidebar's main action: a full-width prominent button, not plain text.
            .menuStyle(.button)
            .buttonStyle(.glassProminent)
            .tint(Palette.accentStrong)
            .controlSize(.large)
            .help("New Profile: start one from the current workspace. The menu has blank, copy and Review Capture.")
            .accessibilityLabel("New profile")
        }
        .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
    }
}
