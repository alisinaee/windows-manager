import SwiftUI
import WMCore

/// Settings section for Space preference backups (P3.6). Drop it into a `Form`; the head wires it in.
/// Restoring always goes through a confirmation alert first.
struct BackupSection: View {
    @ObservedObject var controller: BackupController

    var body: some View {
        Section("Space backups") {
            Button("Back up now") {
                controller.backUpNow()
            }

            if !controller.status.isEmpty {
                Text(controller.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if controller.backups.isEmpty {
                Text("No backups yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.backups) { info in
                    LabeledContent {
                        Button("Restore…") {
                            controller.pendingRestore = info
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.date, format: .dateTime.day().month().year().hour().minute().second())
                            Text(BackupController.describe(info))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .alert("Restore this backup?", isPresented: isPresentingRestore, presenting: controller.pendingRestore) { info in
            Button("Cancel", role: .cancel) {
                controller.pendingRestore = nil
            }
            Button("Restore", role: .destructive) {
                controller.pendingRestore = nil
                controller.restore(info, confirmed: true)
            }
        } message: { info in
            Text("Restores the Space settings from \(info.date.formatted(date: .abbreviated, time: .shortened)). "
                + "Mission Control and the Dock will flicker for a few seconds. Open windows are not closed.")
        }
    }

    private var isPresentingRestore: Binding<Bool> {
        Binding(
            get: { controller.pendingRestore != nil },
            set: { if !$0 { controller.pendingRestore = nil } }
        )
    }
}
