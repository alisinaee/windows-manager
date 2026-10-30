import SwiftUI

struct AboutSettingsTab: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        Form {
            Section {
                VStack(spacing: Spacing.s) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Windows Manager").font(.wmTitle)
                    Text("Version \(AppInfo.version) (\(AppInfo.build))")
                        .foregroundStyle(.secondary)
                    Text("Saves and restores your windows, Spaces and monitors layout.")
                        .font(.wmCaption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.m)
            }
            Section {
                Button("Check for Updates…") {
                    UpdateController.shared.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text(updates.isConfigured ? "Updates are checked against the release appcast." : UpdateController.notConfiguredText)
            }
            Section("Support") {
                Button("Report a Bug…") {
                    BugReportWindowController.shared.show()
                }
            }
        }
        .formStyle(.grouped)
    }
}
