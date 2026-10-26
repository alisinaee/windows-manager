import AppIntents

struct WindowsManagerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunProfileIntent(),
            phrases: [
                "Run a profile in \(.applicationName)",
                "Restore a workspace with \(.applicationName)",
            ],
            shortTitle: "Run profile",
            systemImageName: "rectangle.3.group"
        )
        AppShortcut(
            intent: CaptureWorkspaceIntent(),
            phrases: [
                "Capture my workspace with \(.applicationName)",
                "Save windows in \(.applicationName)",
            ],
            shortTitle: "Capture workspace",
            systemImageName: "camera.viewfinder"
        )
    }
}
