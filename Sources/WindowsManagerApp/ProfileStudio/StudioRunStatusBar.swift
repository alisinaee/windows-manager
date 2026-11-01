import SwiftUI

/// Run progress under the map. Silent while idle: the missing-Accessibility case is the detail column's banner.
struct StudioRunStatusBar: View {
    @ObservedObject var app: AppState

    var body: some View {
        if app.status != .idle {
            Divider()
            RunStatusLine(app: app).lineLimit(1).font(.wmCaption)
                .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.xs)
        }
    }
}
