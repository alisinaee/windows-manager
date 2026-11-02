import SwiftUI

/// Label and value on one line: the label keeps its width, the value takes the rest and truncates with an ellipsis.
struct InspectorRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            configuration.label
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            configuration.content
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .layoutPriority(1)
        }
    }
}
