import SwiftUI

struct AboutSettingsTab: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Windows Manager")
                .font(.title2.bold())
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .foregroundStyle(.secondary)
            Text("Saves and restores your windows, Spaces and monitors layout.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Button("Check for Updates…") {
                UpdateController.shared.checkForUpdates()
            }
            .disabled(!updates.canCheckForUpdates)
            .padding(.top, 12)
            Button("Report a Bug…") {
                BugReportWindowController.shared.show()
            }
            Text(updates.isConfigured ? "Updates are checked against the release appcast." : UpdateController.notConfiguredText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
