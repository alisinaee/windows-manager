import SwiftUI

/// Placeholder settings window: General / Profiles / About.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProfilesSettingsTab()
                .tabItem { Label("Profiles", systemImage: "rectangle.3.group") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 320)
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            LabeledContent("Accessibility") {
                Text(appState.isAccessibilityTrusted ? "Allowed" : "Not allowed")
                    .foregroundStyle(appState.isAccessibilityTrusted ? Color.green : Color.orange)
            }
            Text("General settings will appear here.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { appState.refreshPermissions() }
    }
}

private struct ProfilesSettingsTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.profiles.isEmpty {
            Text("Profiles will appear here.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(appState.profiles, id: \.self) { Text($0) }
        }
    }
}

private struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Windows Manager")
                .font(.title2.bold())
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .foregroundStyle(.secondary)
            Text("Credits will appear here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
