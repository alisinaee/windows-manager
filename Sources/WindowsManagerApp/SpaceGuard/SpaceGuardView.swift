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
            Toggle("Ask to fix when the order drifts", isOn: Binding(
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

            Button("Fix") {
                controller.fix()
            }
            .disabled(controller.report?.drifts.isEmpty ?? true)
            Text("Fix never changes the order by itself. It shows the command to run: spaceslab order-file apply.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Shown before the first check, when the Dock setting can be read directly.
    private static func mruWarningIfOn() -> String? {
        SpaceGuard.mruWarning(DriftWatcher.liveMruSpaces())
    }
}
