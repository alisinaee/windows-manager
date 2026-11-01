import SwiftUI

/// A switch with a one-sentence caption under it.
struct InspectorToggleRow: View {
    let title: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Palette.accent)
                .help("Turn \(title) on or off")
            if let caption {
                Text(caption).font(.wmCaption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
