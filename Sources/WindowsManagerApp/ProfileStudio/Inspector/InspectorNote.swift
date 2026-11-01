import SwiftUI

/// An inline warning or info line inside a panel.
struct InspectorNote: View {
    let text: String
    var tone: Tone = .warning

    var body: some View {
        Label {
            Text(text).font(.wmCaption).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: tone.symbol).foregroundStyle(tone.color)
        }
        .accessibilityElement(children: .combine)
    }
}
