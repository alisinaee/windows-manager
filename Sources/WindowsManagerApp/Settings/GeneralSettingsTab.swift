import AppKit
import SwiftUI

struct GeneralSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        Form {
            Section("Accessibility") {
                LabeledContent("Status") {
                    Text(appState.isAccessibilityTrusted ? "Allowed" : "Not allowed")
                        .foregroundStyle(appState.isAccessibilityTrusted ? Tone.success.color : Tone.warning.color)
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
                    Banner(tone: .danger, title: "Launch at login failed", message: error,
                           actionLabel: "Open Login Items", action: {
                               if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                                   NSWorkspace.shared.open(url)
                               }
                           })
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
