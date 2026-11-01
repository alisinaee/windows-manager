import SwiftUI
import WMCore

/// The profile list: a sidebar List with a bottom bar holding the New Profile menu.
struct StudioSidebar: View {
    @ObservedObject var model: ProfileStudioModel

    var body: some View {
        let selection = Binding<UUID?>(get: { model.selectedID }, set: { model.requestSelect($0) })
        VStack(spacing: 0) {
            if let notice = model.newProfileNotice {
                Banner(tone: .warning, title: notice, onDismiss: { model.newProfileNotice = nil })
                    .padding(.horizontal, Spacing.s).padding(.top, Spacing.xs)
                    .accessibilityIdentifier("newProfileNotice")
            }
            List(selection: selection) {
                ForEach(model.rows) { row in
                    ProfileStudioRowView(row: row, isSelected: model.selectedID == row.id)
                        .tag(row.id)
                        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                        .contextMenu { rowMenu(row) }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Profiles")
            .onDeleteCommand { if let row = model.selectedRow { model.requestDelete(row) } }
            .overlay {
                if model.rows.isEmpty {
                    ContentUnavailableView {
                        Label("No Profiles", systemImage: "rectangle.3.group")
                    } actions: {
                        Button("New Profile") { model.beginNewProfile() }
                    }
                }
            }
            if !model.skipped.isEmpty {
                Text("Could not read: \(model.skipped.joined(separator: ", "))")
                    .font(.wmCaption).foregroundStyle(.secondary)
                    .padding(Spacing.s).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            StudioNewProfileMenu(model: model, capture: model.capture)
        }
    }

    @ViewBuilder private func rowMenu(_ row: ProfileStudioRow) -> some View {
        Button("Run") { model.run(row: row) }
            .disabled(AppState.current?.canAct != true || model.mode == .edit)
        Divider()
        Button("Rename…") { model.beginRename(row) }.disabled(!model.canChangeRows)
        Button("Duplicate") { model.duplicate(row) }.disabled(!model.canChangeRows)
        Button("Export…") { model.export(row) }
        Divider()
        Button("Delete…", role: .destructive) { model.requestDelete(row) }.disabled(!model.canChangeRows)
    }
}
