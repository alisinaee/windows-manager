import SwiftUI
import WMCore

/// Settings section for the Space guard. Drop it into a `Form`, for example in the Settings window.
struct SpaceGuardView: View {
    @ObservedObject var controller: SpaceGuardController

    var body: some View {
        Section("Space order") {
            LabeledContent("Status") {
                Text(controller.status)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if let checked = controller.lastChecked {
                LabeledContent("Last checked") {
                    Text(checked, style: .time)
                        .foregroundStyle(.secondary)
                }
            }

            if let report = controller.report {
                ForEach(report.drifts, id: \.displayID) { drift in
                    Text(drift.summary)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                ForEach(report.missingDisplayIDs, id: \.self) { id in
                    Text("\(id): this display is not connected, so its Spaces cannot be checked.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let warning = controller.report?.mruSpacesWarning ?? Self.mruWarningIfOn() {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Toggle("Watch Space order", isOn: Binding(
                get: { controller.settings.watchEnabled },
                set: { controller.setWatch($0) }
            ))
            Toggle("Show \"Fix available\" when the order drifts", isOn: Binding(
                get: { controller.settings.autoFix },
                set: { controller.setAutoFix($0) }
            ))

            Button("Set current order as expected") {
                controller.setExpectedFromCurrentOrder()
            }
            if let source = controller.settings.expectedSource {
                Text("Expected order from: \(source)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button("Check now") {
                controller.checkNow()
            }
            .disabled(!controller.settings.hasExpectedOrder)

            HStack {
                Button("Fix") {
                    controller.prepareFix()
                }
                .disabled((controller.report?.drifts.isEmpty ?? true) || controller.isRepairing)
                if controller.fixAvailable {
                    Text("Fix available")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
            }
            Text("Fix asks first, saves a backup, then moves Spaces back to the expected order. It never runs by itself.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .alert("Repair the Space order?", isPresented: Binding(
            get: { controller.pendingRepair != nil },
            set: { _ in }   // the buttons below clear the plan; dismissal alone never decides
        )) {
            Button("Repair") { controller.confirmFix() }
            Button("Cancel", role: .cancel) { controller.cancelFix() }
        } message: {
            Text(controller.repairSummary)
        }
    }

    /// Shown before the first check, when the Dock setting can be read directly.
    private static func mruWarningIfOn() -> String? {
        SpaceGuard.mruWarning(DriftWatcher.liveMruSpaces())
    }
}
