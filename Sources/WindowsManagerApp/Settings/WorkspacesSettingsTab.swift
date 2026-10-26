import SwiftUI
import WMCore

/// Snap settings as an observable object (the target avoids the @State macro). Every change is saved
/// through SnapMonitor.saveSettings and starts or stops the monitor.
@MainActor
final class SnapSettingsModel: ObservableObject {
    @Published var settings: SnapSettings = SnapMonitor.loadSettings() {
        didSet {
            guard settings != oldValue else { return }
            SnapMonitor.saveSettings(settings)
            if settings.enabled { SnapMonitor.shared.startIfPossible() }
            else if SnapMonitor.shared.isRunning { SnapMonitor.shared.stop() }
        }
    }
    /// Whether any layout is saved. The layout editor saves elsewhere, so this is refreshed when the tab appears.
    @Published private(set) var hasLayouts = false

    init() { refreshLayouts() }

    func refreshLayouts() {
        hasLayouts = !((try? LayoutStore().load()) ?? []).isEmpty
    }
}

/// Draft text of one workspace name. Typing changes only the draft; the name is saved on submit or focus loss.
@MainActor
final class WorkspaceNameDraftModel: ObservableObject {
    @Published var text: String

    init(name: String) { text = name }
}

/// One workspace row. Its name edits a local draft, committed on submit or when focus leaves the field.
private struct WorkspaceNameRow: View {
    let workspace: Workspace
    let isActive: Bool
    let rename: (String) -> Void
    let delete: () -> Void

    @StateObject private var draft: WorkspaceNameDraftModel
    @FocusState private var focused: Bool

    init(workspace: Workspace, isActive: Bool, rename: @escaping (String) -> Void, delete: @escaping () -> Void) {
        self.workspace = workspace
        self.isActive = isActive
        self.rename = rename
        self.delete = delete
        _draft = StateObject(wrappedValue: WorkspaceNameDraftModel(name: workspace.name))
    }

    var body: some View {
        HStack {
            TextField("Name", text: $draft.text)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .onChange(of: workspace.name) { _, name in
                    if !focused { draft.text = name }
                }
            if isActive { Text("active").foregroundStyle(.secondary) }
            Button("Delete", action: delete)
        }
    }

    private func commit() {
        let name = WorkspaceNameEdit.committedName(draft: draft.text, current: workspace.name)
        if name != workspace.name { rename(name) }
        draft.text = name
    }
}

struct WorkspacesSettingsTab: View {
    @ObservedObject private var workspaces = WorkspaceController.shared
    @StateObject private var snap = SnapSettingsModel()
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Virtual workspaces") {
                Toggle("Virtual workspaces", isOn: $workspaces.isEnabled)
                Text("Experimental. Switching hides the windows of the other workspaces. Off by default; turning it off brings every window back.")
                    .font(.footnote).foregroundStyle(.secondary)
                if workspaces.isEnabled {
                    Picker("Three-finger swipe", selection: $workspaces.naturalSwipe) {
                        Text("Natural").tag(true)
                        Text("Inverted").tag(false)
                    }
                    Toggle("Follow Cmd+Tab and Dock clicks", isOn: $workspaces.followAppSwitch)
                }
                if let text = workspaces.statusText {
                    Text(text).font(.footnote).foregroundStyle(.orange)
                }
            }
            if workspaces.isEnabled {
                Section("Workspaces") {
                    ForEach(workspaces.workspaces) { ws in
                        WorkspaceNameRow(
                            workspace: ws,
                            isActive: ws.id == workspaces.activeID,
                            rename: { workspaces.rename(ws.id, to: $0) },
                            delete: { workspaces.delete(ws.id) })
                    }
                    Button("New workspace") { workspaces.createWorkspace() }
                }
            }
            Section("Snapping") {
                Toggle("Snap windows into layout zones", isOn: $snap.settings.enabled)
                if let hint = snapHint {
                    Text(hint).font(.footnote).foregroundStyle(.orange)
                }
                Picker("Modifier key", selection: $snap.settings.modifier) {
                    Text("Option").tag(SnapModifier.option)
                    Text("Control").tag(SnapModifier.control)
                    Text("Command").tag(SnapModifier.command)
                    Text("Shift").tag(SnapModifier.shift)
                }
                Stepper(value: $snap.settings.gap, in: 0...64, step: 2) {
                    Text("Gap: \(Int(snap.settings.gap)) pt")
                }
                Text("Hold the modifier while dragging a window to see the zones of a layout. Needs Accessibility and at least one saved layout.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { snap.refreshLayouts() }
    }

    /// Why snapping is switched on but cannot run. Nil when it is off or nothing blocks it.
    private var snapHint: String? {
        guard snap.settings.enabled else { return nil }
        if !appState.isAccessibilityTrusted {
            return "Snapping is on but not running: Accessibility is not allowed for this app. Allow it in System Settings, then turn snapping off and on."
        }
        if !snap.hasLayouts {
            return "Snapping is on but not running: save a layout first."
        }
        return nil
    }
}
