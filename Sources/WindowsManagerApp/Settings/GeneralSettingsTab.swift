import SwiftUI

struct GeneralSettingsTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Accessibility") {
                LabeledContent("Status") {
                    Text(appState.isAccessibilityTrusted ? "Allowed" : "Not allowed")
                        .foregroundStyle(appState.isAccessibilityTrusted ? Color.green : Color.orange)
                }
                if !appState.isAccessibilityTrusted {
                    Button("Grant Accessibility Access…") { appState.requestAccessibility() }
                    Text("Windows Manager needs Accessibility access to read and move windows.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Launch") {
                Text("Windows Manager lives in the menu bar and has no Dock icon. To start it at login, add it in System Settings > General > Login Items.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { appState.refreshPermissions() }
    }
}
