import SwiftUI

/// A titled card of rows. Without a title it is just the card.
struct InspectorSection<Content: View>: View {
    var title: String?
    private let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let title {
                Text(title).font(.wmSection).accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: Spacing.s) { content }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.medium))
        }
    }
}
