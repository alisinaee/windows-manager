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
    private var inView: Bool { front && studio.mode == .view && studio.selectedRow != nil }
    private var inEdit: Bool { front && studio.mode == .edit && studio.builder != nil }
    private var sheetOpen: Bool { studio.isPreviewPresented || studio.isSaveSheetPresented }

    /// Undo / Redo: the Studio's draft history in Edit mode; otherwise the normal responder-chain edit action.
    private func undoRedo(_ selector: String, builderAction: (ProfileBuilderModel) -> Void) {
        if inEdit, let builder = studio.builder { builderAction(builder) }
        else { NSApp.sendAction(Selector((selector)), to: nil, from: nil) }
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { undoRedo("undo:") { $0.undo() } }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { undoRedo("redo:") { $0.redo() } }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Profile") { studio.saveThen(nil) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!inEdit || sheetOpen || (studio.builder?.blocksSaving ?? true))
        }
        CommandMenu("Studio") {
            Button("New Profile") { studio.beginNewProfile() }.disabled(!canNew)
            Button("Command Palette") { CommandPaletteController.present(studio: studio) }
                .keyboardShortcut("k", modifiers: .command).disabled(!front || sheetOpen)
            Button("Run Profile") { if let id = studio.selectedRow?.id { app.run(id: id) } }
                .keyboardShortcut(.return, modifiers: .command).disabled(!canRun)
            Divider()
            Button(studio.mode == .edit ? "View Profile" : "Edit Profile") {
                studio.requestMode(studio.mode == .edit ? .view : .edit)
            }
            .keyboardShortcut("e", modifiers: .command).disabled(!front || studio.selectedRow == nil || sheetOpen)
            Button("Add App") { studio.isAddAppPresented = true }
                .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(!inEdit || sheetOpen)
            Divider()
            Button(studio.isCompareOn ? "Stop Comparing" : "Compare with Mac") { studio.setCompare(!studio.isCompareOn) }
                .keyboardShortcut("l", modifiers: .command).disabled(!inView || sheetOpen)
            Button("Refresh Comparison") { studio.refreshCompare() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!inView || !studio.isCompareOn || studio.isComparing || studio.compareError != nil || sheetOpen)
            Button("Preview Restore") { studio.previewScope = .whole; studio.isPreviewPresented = true }
                .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!inView || sheetOpen)
            Divider()
            Button(studio.isSidebarShown ? "Hide Sidebar" : "Show Sidebar") { studio.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .option]).disabled(!front)
            Divider()
            Button("Previous Desktop") { studio.activeMap?.stepDesktop(forward: false) }
                .keyboardShortcut("[", modifiers: .command).disabled(!canZoom || studio.mode != .view)
            Button("Next Desktop") { studio.activeMap?.stepDesktop(forward: true) }
                .keyboardShortcut("]", modifiers: .command).disabled(!canZoom || studio.mode != .view)
            Divider()
            Button("Zoom In") { studio.activeMap?.zoomBy(1.25) }.keyboardShortcut("=", modifiers: .command).disabled(!canZoom)
            Button("Zoom Out") { studio.activeMap?.zoomBy(1 / 1.25) }.keyboardShortcut("-", modifiers: .command).disabled(!canZoom)
            Button("Actual Size") { studio.activeMap?.actualSize() }.keyboardShortcut("0", modifiers: .command).disabled(!canZoom)
            Button("Fit to Window") { studio.activeMap?.fit() }.keyboardShortcut("1", modifiers: .command).disabled(!canZoom)
            Button("Zoom to Selection") { studio.activeMap?.zoomToSelection() }
                .keyboardShortcut("2", modifiers: .command).disabled(!canZoom)
        }
    }
}
