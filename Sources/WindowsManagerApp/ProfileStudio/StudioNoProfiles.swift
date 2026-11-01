import SwiftUI

/// The detail column when the profile list is empty: a normal Studio window with this in the middle.
struct StudioNoProfiles: View {
    @ObservedObject var model: ProfileStudioModel

    var body: some View {
        ContentUnavailableView {
            Label("No Profiles", systemImage: "rectangle.3.group")
        } description: {
            Text("Capture the windows you have open now, or start a new profile and arrange it yourself.")
        } actions: {
            ViewThatFits {
                HStack { capture; newProfile }
                VStack { capture; newProfile }
            }
        }
    }

    private var capture: some View {
        Button { model.beginCapture() } label: { Label("Capture Current Desktop", systemImage: "camera.viewfinder") }
            .buttonStyle(.borderedProminent).tint(Palette.accentStrong).controlSize(.large)
            .help("Capture the windows you have open now as a new profile")
            .accessibilityLabel("Capture current desktop as a profile")
    }

    private var newProfile: some View {
        Button { model.beginNewProfile() } label: { Label("New Profile", systemImage: "plus") }
            .controlSize(.large)
            .help("Start a new profile from the current workspace, as an editable draft")
            .accessibilityLabel("New profile")
    }
}
