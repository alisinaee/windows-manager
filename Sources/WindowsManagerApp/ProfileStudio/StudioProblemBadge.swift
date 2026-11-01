import SwiftUI
import WMCore

/// Draft check count in Edit mode; hidden when there is nothing to fix. A click lists the problems.
struct StudioProblemBadge: View {
    @ObservedObject var builder: ProfileBuilderModel
    @State private var isListShown = false

    private var statusText: String {
        let e = builder.errorCount, w = builder.warningCount
        if e == 0 && w == 0 { return "No problems" }
        var parts: [String] = []
        if e > 0 { parts.append("\(e) problem\(e == 1 ? "" : "s")") }
        if w > 0 { parts.append("\(w) warning\(w == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let count = builder.errorCount + builder.warningCount
        if count > 0 {
            Button { isListShown = true } label: {
                Label("\(count) Problem\(count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
            }
            .help("Show what the draft check found")
            .accessibilityLabel("Draft check: \(statusText)")
            .popover(isPresented: $isListShown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(Array(builder.draftIssues.enumerated()), id: \.offset) { _, issue in
                        InspectorNote(text: issue.message, tone: issue.severity == .error ? .danger : .warning)
                    }
                }
                .padding(Spacing.m)
                .frame(width: 300, alignment: .leading)
            }
        }
    }
}
