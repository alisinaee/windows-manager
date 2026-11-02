import SwiftUI
import WMCore

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

/// The unsaved new-profile row at the top of the sidebar, with a "Draft" or "Recovered" badge.
struct ProfileStudioDraftRowView: View {
    let name: String
    let badge: StudioDraftBadge

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "square.and.pencil").frame(width: 22).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Text(badge.rawValue).font(.wmCaption).foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xs).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.s).padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(badge.rawValue.lowercased()), not saved yet")
    }
}
