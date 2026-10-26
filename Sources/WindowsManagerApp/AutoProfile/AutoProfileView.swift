import SwiftUI
import WMCore

/// The Auto profile section for a Settings `Form`. Place `AutoProfileView()` inside the Form.
struct AutoProfileView: View {
    @ObservedObject var controller: AutoProfileController

    @MainActor
    init(controller: AutoProfileController? = nil) {
        self.controller = controller ?? AutoProfileController.shared
    }

    var body: some View {
        Section("Auto profile") {
            Toggle("Run a profile automatically", isOn: enabledBinding)
            Toggle("When the monitors change", isOn: triggerBinding(\.monitorChange))
                .disabled(!controller.settings.enabled)
            Toggle("After the Mac wakes", isOn: triggerBinding(\.wake))
                .disabled(!controller.settings.enabled)
            Toggle("After the screen is unlocked", isOn: triggerBinding(\.unlock))
                .disabled(!controller.settings.enabled)

            Picker("Profile for this setup", selection: mappingBinding) {
                Text("None").tag(UUID?.none)
                ForEach(orderedEntries) { entry in
                    Text(label(for: entry)).tag(UUID?.some(entry.id))
                }
            }
            .disabled(!controller.settings.enabled || controller.currentMonitorSetKey.isEmpty)

            Stepper("Wait \(Int(controller.settings.delaySeconds)) s after an event",
                    value: delayBinding, in: 0...30, step: 1)
                .disabled(!controller.settings.enabled)
            Stepper("At most one run every \(Int(controller.settings.cooldownSeconds)) s",
                    value: cooldownBinding, in: 0...600, step: 10)
                .disabled(!controller.settings.enabled)

            Text(setupText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(controller.lastRunText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear { controller.refresh() }
    }

    // MARK: Text

    /// Profiles captured on the monitors connected now come first.
    private var orderedEntries: [AutoProfileEntry] {
        let key = controller.currentMonitorSetKey
        return controller.entries.sorted { lhs, rhs in
            let lm = lhs.monitorSetKey == key, rm = rhs.monitorSetKey == key
            if lm != rm { return lm }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func label(for entry: AutoProfileEntry) -> String {
        entry.monitorSetKey == controller.currentMonitorSetKey ? "\(entry.name) (this setup)" : entry.name
    }

    private var setupText: String {
        let count = controller.currentMonitorCount
        return count == 1 ? "1 monitor connected" : "\(count) monitors connected"
    }

    // MARK: Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(get: { controller.settings.enabled },
                set: { value in controller.update { $0.enabled = value } })
    }

    private func triggerBinding(_ keyPath: WritableKeyPath<AutoProfileTriggers, Bool>) -> Binding<Bool> {
        Binding(get: { controller.settings.triggers[keyPath: keyPath] },
                set: { value in controller.update { $0.triggers[keyPath: keyPath] = value } })
    }

    /// The profile chosen for the monitor set connected now. "None" removes the choice.
    private var mappingBinding: Binding<UUID?> {
        Binding(get: { controller.settings.mapping[controller.currentMonitorSetKey] },
                set: { value in
                    let key = controller.currentMonitorSetKey
                    guard !key.isEmpty else { return }
                    controller.update { $0.mapping[key] = value }
                })
    }

    private var delayBinding: Binding<Double> {
        Binding(get: { controller.settings.delaySeconds },
                set: { value in controller.update { $0.delaySeconds = value } })
    }

    private var cooldownBinding: Binding<Double> {
        Binding(get: { controller.settings.cooldownSeconds },
                set: { value in controller.update { $0.cooldownSeconds = value } })
    }
}
