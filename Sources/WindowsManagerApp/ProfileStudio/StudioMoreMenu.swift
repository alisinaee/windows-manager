import SwiftUI
import WMCore

/// The single overflow menu: Live sync and Add App (Edit mode only), and the debug log switch.
struct StudioMoreMenu: View {
    @ObservedObject var model: ProfileStudioModel
    /// The open draft in Edit mode; nil in View mode.
    var builder: ProfileBuilderModel?

    var body: some View {
        Menu {
            if let builder {
                Toggle("Live", isOn: Binding(get: { builder.isLive }, set: { builder.setLive($0) }))
                    .help("Live: the draft follows your real windows and updates every 2 s. Off: the draft changes only when you edit it.")
                Button { model.isAddAppPresented = true } label: { Label("Add App…", systemImage: "plus") }
                    .help("Add an app to the profile (Shift+Cmd+A)")
                Divider()
            }
            DebugLogToggle()
        } label: { Label("More", systemImage: "ellipsis.circle") }
        .menuIndicator(.hidden)
        .help("More: Live sync, Add App and debug options")
        .accessibilityLabel("More actions")
        .popover(isPresented: $model.isAddAppPresented, arrowEdge: .bottom) {
            if let builder {
                AppLibraryView(builder: builder, onClose: { model.isAddAppPresented = false })
            }
        }
    }
}
