import SwiftUI
import WMCore

/// Fills the shared `StudioInspector` for one mode. View mode passes `builder: nil` and the panels render read-only
/// from the map's profile; Edit mode passes the builder, whose profile is the draft.
struct StudioInspectorHost: View {
    @Binding var tab: StudioInspectorTab
    @ObservedObject var map: ProfileMapModel
    let builder: ProfileBuilderModel?
    /// The plan behind the live status (View mode, Compare on).
    var plan: RestorePlan?
    var isCompareOn: Bool

    private var profile: Profile? { builder?.profile ?? map.profile }

    private var title: String {
        switch tab {
        case .inspector: MapInspectorView.title(for: map)
        case .options: "Profile options"
        case .launchOrder: "Launch order"
        case .actions: "Profile actions"
        }
    }

    var body: some View {
        StudioInspector(tab: $tab, title: title) { tab in
            switch tab {
            case .inspector:
                MapInspectorView(map: map, plan: plan, isCompareOn: isCompareOn)
            case .options:
                if let profile {
                    ProfileOptionsPanel(profile: profile, builder: builder)
                } else {
                    noProfile
                }
            case .launchOrder:
                if let profile {
                    LaunchOrderEditor(profile: profile, builder: builder)
                } else {
                    noProfile
                }
            case .actions:
                if let profile {
                    ProfileActionsPanel(profile: profile, builder: builder)
                } else {
                    noProfile
                }
            }
        } footer: { tab in
            if tab == .launchOrder, let profile {
                LaunchFooter(profile: profile, builder: builder)
            }
        }
    }

    private var noProfile: some View {
        ContentUnavailableView("No Profile Open", systemImage: "rectangle.3.group")
    }
}
