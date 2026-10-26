import SwiftUI
import WMCore

/// What the grid controls do to the layout being edited. The editor supplies these closures. Each one returns
/// an error message to show, or nil when it worked.
struct LayoutGridActions {
    /// Replaces the zones with a rows x columns grid.
    var applyGrid: (_ rows: Int, _ columns: Int) -> String?
    /// Merges the zones that are selected in the editor.
    var mergeSelected: () -> String?
    /// Removes the selected zone and gives its area to a neighbour.
    var removeSelected: () -> String?
}

/// Holds the stepper values and the last message. The editor creates one and keeps it. No @State here either.
@MainActor
final class LayoutGridControlsModel: ObservableObject {
    @Published var rows = 2
    @Published var columns = 2
    @Published var message: String?

    private let actions: LayoutGridActions

    init(actions: LayoutGridActions) {
        self.actions = actions
    }

    func applyGrid() { message = actions.applyGrid(rows, columns) }
    func mergeSelected() { message = actions.mergeSelected() }
    func removeSelected() { message = actions.removeSelected() }
}

/// Grid, merge and remove controls for the layout editor.
struct LayoutGridControls: View {
    @ObservedObject var model: LayoutGridControlsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Grid").font(.headline)
            Stepper("Rows: \(model.rows)", value: $model.rows, in: LayoutBuilder.gridRange)
            Stepper("Columns: \(model.columns)", value: $model.columns, in: LayoutBuilder.gridRange)
            Button("Apply grid") { model.applyGrid() }

            Divider()

            Button("Merge selected zones") { model.mergeSelected() }
            Button("Remove zone", role: .destructive) { model.removeSelected() }

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
    }
}
