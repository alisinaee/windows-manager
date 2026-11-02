import SwiftUI
import WMCore

/// The map of one profile with the Details inspector on its right. Like `ProfileMapHost`, but it owns the
/// `ProfileMapModel` here so the inspector can follow the map's selection.
struct StudioMapHost: View {
    let row: ProfileStudioRow
    @ObservedObject var model: ProfileStudioModel
    @Binding var inspectorTab: StudioInspectorTab
    @StateObject private var map = ProfileMapModel()

    private var mapPane: some View {
        VStack(spacing: 0) {
            if let error = model.compareError {
                Banner(tone: .danger, title: "Compare problem", message: error).padding(Spacing.s)
            }
            ProfileMapCanvas(model: map)
            if let app = AppState.current {
                StudioRunStatusBar(app: app)
            }
        }
    }

    var body: some View {
        mapPane
            .inspector(isPresented: $model.isInspectorShown) {
                StudioInspectorHost(tab: $inspectorTab, map: map, builder: nil, plan: model.comparePlan,
                                    isCompareOn: model.isCompareOn)
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 720)
            }
            .task(id: row) { map.load(try? AppState.current?.store.load(row.id)) }
            .onChange(of: model.liveStatus) { _, newValue in map.status = newValue }
            .onAppear { map.status = model.liveStatus; model.activeMap = map }
    }
}
