import SwiftUI
import WMCore

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
        .commands { StudioCommands(studio: ProfileStudioWindowController.shared.model, app: appState) }
    }
}

/// Profile Studio menu items. They own the shortcuts (the in-window buttons carry none, so a key never fires twice)
/// and are disabled, not hidden, unless the Studio is the key window and the action is allowed.
struct StudioCommands: Commands {
    @ObservedObject var studio: ProfileStudioModel
    @ObservedObject var app: AppState

    private var front: Bool { studio.isFront }
    private var canNew: Bool { front && NewProfileGate.refusal(isEditing: studio.mode == .edit, hasUnsavedChanges: studio.hasUnsavedChanges) == nil }
    private var canRun: Bool { front && studio.mode == .view && studio.selectedRow != nil && app.canAct }
    private var canZoom: Bool { front && studio.activeMap != nil }

    var body: some Commands {
        CommandMenu("Studio") {
            Button("New Profile") { studio.beginNewProfile() }.disabled(!canNew)
            Button("Run Profile") { if let id = studio.selectedRow?.id { app.run(id: id) } }
                .keyboardShortcut(.return, modifiers: .command).disabled(!canRun)
            Divider()
            Button(studio.isSidebarShown ? "Hide Sidebar" : "Show Sidebar") { studio.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .option]).disabled(!front)
            Divider()
            Button("Zoom In") { studio.activeMap?.zoomBy(1.25) }.keyboardShortcut("=", modifiers: .command).disabled(!canZoom)
            Button("Zoom Out") { studio.activeMap?.zoomBy(1 / 1.25) }.keyboardShortcut("-", modifiers: .command).disabled(!canZoom)
            Button("Actual Size") { studio.activeMap?.actualSize() }.keyboardShortcut("0", modifiers: .command).disabled(!canZoom)
            Button("Fit to Window") { studio.activeMap?.fit() }.keyboardShortcut("1", modifiers: .command).disabled(!canZoom)
        }
    }
}
