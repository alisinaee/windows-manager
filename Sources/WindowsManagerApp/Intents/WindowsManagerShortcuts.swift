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
        AppShortcut(
            intent: VerifyProfileIntent(),
            phrases: [
                "Verify a profile in \(.applicationName)",
                "Check my workspace with \(.applicationName)",
            ],
            shortTitle: "Verify profile",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: CreateProfileIntent(),
            phrases: [
                "Create a profile in \(.applicationName)",
                "New workspace in \(.applicationName)",
            ],
            shortTitle: "Create profile",
            systemImageName: "plus.rectangle.on.rectangle"
        )
        AppShortcut(
            intent: ListProfilesIntent(),
            phrases: [
                "List profiles in \(.applicationName)",
                "Show my workspaces in \(.applicationName)",
            ],
            shortTitle: "List profiles",
            systemImageName: "list.bullet.rectangle"
        )
        AppShortcut(
            intent: DuplicateProfileIntent(),
            phrases: [
                "Duplicate a profile in \(.applicationName)",
                "Copy a workspace in \(.applicationName)",
            ],
            shortTitle: "Duplicate profile",
            systemImageName: "doc.on.doc"
        )
    }
}
