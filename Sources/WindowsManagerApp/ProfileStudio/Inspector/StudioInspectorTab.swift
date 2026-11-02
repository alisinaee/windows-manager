import Foundation

/// The three pages of the Details inspector. The case names are used by the UX harness.
enum StudioInspectorTab: String, CaseIterable, Identifiable {
    case inspector = "Selection"
    case options = "Options"
    case launchOrder = "Launch"
    case actions = "Actions"

    var id: String { rawValue }
}
