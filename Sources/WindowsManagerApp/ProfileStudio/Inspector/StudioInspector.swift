import SwiftUI

/// The one container of the Details inspector, shared by View and Edit mode. The tab bar and title are a pinned
/// top bar, the body is a single ScrollView, and the optional footer is a pinned bottom bar. Panels are plain
/// content: no ScrollView, Form, List, background or min width of their own, so switching tabs only swaps the
/// content under the same bars.
struct StudioInspector<Content: View, Footer: View>: View {
    @Binding var tab: StudioInspectorTab
    /// Shown under the tabs: the selected window or Desktop, "Profile options", "Launch order".
    let title: String
    @ViewBuilder var content: (StudioInspectorTab) -> Content
    @ViewBuilder var footer: (StudioInspectorTab) -> Footer

    var body: some View {
        ScrollView(.vertical) {
            content(tab)
                .labeledContentStyle(InspectorRowStyle())
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .id(tab)
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(alignment: .center, spacing: Spacing.s) {
                Picker("Inspector page", selection: $tab) {
                    ForEach(StudioInspectorTab.allCases) { Text($0.rawValue).lineLimit(1).minimumScaleFactor(0.8).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Inspector page")
                .help("Switch between the selection, the profile options and the launch order")
                Text(title).font(.wmSection).lineLimit(1).frame(maxWidth: .infinity, alignment: .center).truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .center)
            .clipped()
        }
        .safeAreaBar(edge: .bottom, spacing: 0) { footer(tab) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details")
    }
}
