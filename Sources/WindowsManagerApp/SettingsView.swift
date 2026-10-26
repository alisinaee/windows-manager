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
            WorkspacesSettingsTab()
                .tabItem { Label("Workspaces", systemImage: "square.stack.3d.up") }
            HotkeysSettingsTab()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            SpacesSettingsTab()
                .tabItem { Label("Spaces", systemImage: "rectangle.3.group.bubble") }
            AutomationSettingsTab()
                .tabItem { Label("Automation", systemImage: "bolt.badge.clock") }
            MonitorsSettingsTab()
                .tabItem { Label("Monitors", systemImage: "display.2") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 680, height: 480)
    }
}
