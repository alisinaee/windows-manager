import AppKit
import SwiftUI
import WMCore

struct GeneralSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var launchAtLogin = LaunchAtLogin()
    @ObservedObject private var appearance = AppearanceManager.shared

    @State private var folderError: String?
    @State private var folderRefresh = 0

    private func chooseProfilesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where Windows Manager keeps its profiles."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyProfilesFolder(url)
    }

    private func applyProfilesFolder(_ url: URL?) {
        do {
            try appState.setProfilesFolder(url)
            folderError = nil
        } catch {
            folderError = error.localizedDescription
        }
        folderRefresh += 1
    }

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
            Section("Profiles folder") {
                LabeledContent("Folder") {
                    Text(appState.store.folder.path)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose…") { chooseProfilesFolder() }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([appState.store.folder])
                    }
                    Button("Reset to default") { applyProfilesFolder(nil) }
                        .disabled(ProfilesLocation.configuredPath == nil)
                }
                Text("Pick a folder in iCloud Drive or Dropbox to sync profiles. Another Mac must pick the same folder.")
                    .font(.wmFootnote)
                    .foregroundStyle(.secondary)
                if let error = folderError {
                    Text(error).font(.wmFootnote).foregroundStyle(Tone.danger.color)
                }
            }
            Section("Launch") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.set($0) }
                ))
                LabeledContent("Status") {
                    HStack(spacing: Spacing.s) {
                        Text(launchAtLogin.statusText)
                            .foregroundStyle(launchAtLogin.needsApproval ? Tone.warning.color : .secondary)
                        Button("Open Login Items") { LaunchAtLogin.openLoginItems() }
                    }
                }
                Text(launchAtLogin.needsApproval
                    ? "macOS is waiting for you: switch Windows Manager on under \"Allow in the Background\" in Login Items & Extensions."
                    : "Optional. When on, macOS lists Windows Manager as a background item and starts it when you log in, so auto profiles run without opening the app. Everything else works without it.")
                    .font(.wmFootnote)
                    .foregroundStyle(.secondary)
                if let error = launchAtLogin.errorText {
                    Banner(tone: .danger, title: "Launch at login failed", message: error,
                           actionLabel: "Open Login Items", action: { LaunchAtLogin.openLoginItems() })
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
        // Approval happens in System Settings; re-read the status when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }
}
