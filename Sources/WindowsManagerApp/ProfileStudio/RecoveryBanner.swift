import SwiftUI
import WMCore

/// "Unsaved changes from <time> were recovered." with Restore and Discard (P9.14).
struct RecoveryBanner: View {
    let draft: RecoveredDraft
    let isStale: Bool
    let restore: () -> Void
    let discard: () -> Void

    private var message: String {
        let time = draft.savedAt.formatted(date: .abbreviated, time: .shortened)
        var text = "Unsaved changes from \(time) were recovered."
        if isStale { text += " The saved profile changed after this draft started, so restoring may overwrite newer changes." }
        return text
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\u{201C}\(draft.profile.name)\u{201D}: recovered draft").font(.wmSection)
                Text(message).font(.wmCaption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s)
            Button("Discard", action: discard)
            Button("Restore", action: restore).buttonStyle(.borderedProminent).tint(Palette.accentStrong)
        }
        .padding(Spacing.s)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        .padding(Spacing.s)
        .accessibilityElement(children: .contain)
    }
}
