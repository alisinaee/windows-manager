import SwiftUI

/// The Settings window: only the tab shell. Each tab lives in Settings/.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProfilesSettingsTab()
                .tabItem { Label("Profiles", systemImage: "rectangle.3.group") }
            WindowRulesSettingsTab()
                .tabItem { Label("Window rules", systemImage: "list.bullet.rectangle") }
            MonitorsSettingsTab()
                .tabItem { Label("Monitors", systemImage: "display.2") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 420)
    }
}
