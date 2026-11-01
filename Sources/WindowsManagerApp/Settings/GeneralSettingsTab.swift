import AppKit
import SwiftUI

struct GeneralSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var launchAtLogin = LaunchAtLogin()
    @ObservedObject private var appearance = AppearanceManager.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Section("Accessibility") {
                LabeledContent("Status") {
                    HStack(spacing: Spacing.s) {
                        Text(appState.isAccessibilityTrusted ? "Allowed" : "Not allowed")
                            .foregroundStyle(appState.isAccessibilityTrusted ? Tone.success.color : Tone.warning.color)
                        if !appState.isAccessibilityTrusted {
                            Button("Grant Access…") { appState.requestAccessibility() }
                        }
                    }
                }
                if !appState.isAccessibilityTrusted {
                    Text("Windows Manager needs Accessibility access to read and move windows.")
                        .font(.wmFootnote)
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
                        .font(.wmFootnote)
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
                    .font(.wmFootnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            appState.refreshPermissions()
            launchAtLogin.refresh()
        }
    }
}
