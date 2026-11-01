import SwiftUI

/// A sidebar row: icon, name and a short subtitle. The capture date is in the tooltip and the window subtitle.
struct ProfileStudioRowView: View {
    let row: ProfileStudioRow
    var isSelected = false

    static func subtitle(_ row: ProfileStudioRow) -> String {
        let windows = "\(row.windowCount) window\(row.windowCount == 1 ? "" : "s")"
        let monitors = "\(row.monitorCount) monitor\(row.monitorCount == 1 ? "" : "s")"
        return "\(windows) · \(monitors)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: row.icon).frame(width: 22).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs / 2) {
                Text(row.name).lineLimit(1).truncationMode(.tail)
                Text(Self.subtitle(row)).font(.wmCaption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.s).padding(.vertical, Spacing.xs)
        .help("\(row.name), captured \(row.capturedAt.formatted(.relative(presentation: .named)))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(Self.subtitle(row)), captured \(row.capturedAt.formatted(.relative(presentation: .named)))")
    }
}
