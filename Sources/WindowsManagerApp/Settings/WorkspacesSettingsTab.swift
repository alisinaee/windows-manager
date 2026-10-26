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
}

struct WorkspacesSettingsTab: View {
    @ObservedObject private var workspaces = WorkspaceController.shared
    @StateObject private var snap = SnapSettingsModel()

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
                        HStack {
                            TextField("Name", text: Binding(get: { ws.name }, set: { workspaces.rename(ws.id, to: $0) }))
                            if ws.id == workspaces.activeID { Text("active").foregroundStyle(.secondary) }
                            Button("Delete") { workspaces.delete(ws.id) }
                        }
                    }
                    Button("New workspace") { workspaces.createWorkspace() }
                }
            }
            Section("Snapping") {
                Toggle("Snap windows into layout zones", isOn: $snap.settings.enabled)
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
    }
}
