import SwiftUI

/// Menu bar app entry point: a MenuBarExtra (no Dock icon, see AppDelegate) and a Settings window.
@main
struct WindowsManagerMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState

    init() {
        // Headless check for tools and scripts: print the facts and quit before any UI exists.
        if CommandLine.arguments.contains("--self-check") {
            SelfCheck.runAndExit()
        }
        _appState = StateObject(wrappedValue: AppState())
    }

    var body: some Scene {
        MenuBarExtra("Windows Manager", systemImage: "rectangle.3.group") {
            MenuBarContent()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
