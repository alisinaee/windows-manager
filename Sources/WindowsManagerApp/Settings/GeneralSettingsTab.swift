import SwiftUI

struct GeneralSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var launchAtLogin = LaunchAtLogin()

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
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.set($0) }
                ))
                if launchAtLogin.needsApproval {
                    Text("Approve Windows Manager in System Settings > General > Login Items.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let error = launchAtLogin.errorText {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                }
                Text("Windows Manager lives in the menu bar and has no Dock icon.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            appState.refreshPermissions()
            launchAtLogin.refresh()
        }
    }
}
