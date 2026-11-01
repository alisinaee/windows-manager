import SwiftUI
import WMCore

/// The bar above the map: one "Apply Part…" menu that previews and applies a single Desktop or monitor.
/// (Checking against the Mac is the toolbar's Check Now.)
struct StudioScopeBar: View {
    @ObservedObject var model: ProfileStudioModel
    @ObservedObject var map: ProfileMapModel

    /// The monitor the map focuses, and the Desktop it shows there (nil for a full-screen Space).
    private var focusedScope: (monitor: RestoreScope, desktop: RestoreScope?, monitorName: String)? {
        guard let uuid = map.focusedDisplayUUID, let profile = map.profile else { return nil }
        let name = profile.displays.first { $0.uuid == uuid }?.name ?? uuid
        var desktop: RestoreScope?
        if let space = map.shownSpace(onDisplay: uuid), space.kind == .desktop, let n = space.desktopNumber {
            desktop = RestoreScope(desktops: [SpaceRef(displayUUID: uuid, desktopNumber: n)])
        }
        return (RestoreScope(displays: [uuid]), desktop, name)
    }

    var body: some View {
        let focus = focusedScope
        HStack(spacing: Spacing.s) {
            Menu {
                Button("This Desktop", systemImage: "rectangle.on.rectangle") {
                    if let scope = focus?.desktop { preview(scope) }
                }
                .disabled(focus?.desktop == nil)
                .help(focus?.desktop == nil ? "The shown Space is not a Desktop" : "Preview and apply only the Desktop shown on \(focus?.monitorName ?? "this monitor")")
                Button("This Monitor", systemImage: "display") {
                    if let scope = focus?.monitor { preview(scope) }
                }
                .disabled(focus == nil)
                .help("Preview and apply only \(focus?.monitorName ?? "the focused monitor")")
            } label: {
                Label("Apply Part…", systemImage: "rectangle.on.rectangle")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Preview and apply only one Desktop or one monitor of this profile")
            Spacer()
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
    }

    private func preview(_ scope: RestoreScope) {
        model.previewScope = scope
        model.isPreviewPresented = true
    }
}
