import KeyboardShortcuts
import SwiftUI
import WMCore

/// Global hotkeys: workspace switching, snap to zone and one per saved profile.
struct HotkeysSettingsTab: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var workspaces = WorkspaceController.shared

    var body: some View {
        Form {
            Section("Workspaces") {
                KeyboardShortcuts.Recorder("Next workspace", name: .nextWorkspace)
                KeyboardShortcuts.Recorder("Previous workspace", name: .previousWorkspace)
                if !workspaces.isEnabled {
                    Text("These only work while Virtual workspaces is turned on in the Workspaces tab.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Snap to zone") {
                ForEach(0..<9, id: \.self) { i in
                    KeyboardShortcuts.Recorder("Zone \(i + 1)", name: KeyboardShortcuts.Name.snapZones[i])
                }
                Text("Moves the frontmost window into that zone of the layout for its display.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Profiles") {
                if state.savedProfiles.isEmpty {
                    Text("No saved profiles yet.").foregroundStyle(.secondary)
                }
                ForEach(state.savedProfiles) { profile in
                    KeyboardShortcuts.Recorder(profile.name, name: .profile(profile.id))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { HotkeyController.shared.syncProfiles() }
    }
}
