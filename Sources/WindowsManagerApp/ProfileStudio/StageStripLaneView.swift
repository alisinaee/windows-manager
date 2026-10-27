import AppKit
import SwiftUI
import WMCore

/// The Stage Manager strip of one monitor (P6.58): one card per stage group whose windows are not active.
/// The lane is laid out by the canvas (its frame is the lane rect); the cards stack from the top.
struct StageStripLaneView: View {
    let groups: [StageStripGroup]
    /// The selected window, so the card holding it shows as selected.
    let selectedWindowID: UUID?
    var metrics = MapMetrics()
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(groups) { group in
                StageStripCard(group: group,
                               isSelected: selectedWindowID.map { group.windowIDs.contains($0) } ?? false,
                               metrics: metrics,
                               onSelect: { if let first = group.windowIDs.first { onSelect(first) } })
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.horizontal, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .windowBackgroundColor).opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stage Manager strip")
    }
}

/// One stage in the strip: its label, the app icons and the number of windows.
private struct StageStripCard: View {
    let group: StageStripGroup
    let isSelected: Bool
    let metrics: MapMetrics
    let onSelect: () -> Void

    /// Icons shown on the card; more than this collapse into a "+n" text.
    private let maxIcons = 3

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 3) {
                Text(group.label)
                    .font(.system(size: metrics.font(9), weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.6)
                ForEach(Array(group.apps.prefix(maxIcons).enumerated()), id: \.offset) { _, app in
                    Image(nsImage: AppIconCache.icon(for: app))
                        .resizable()
                        .frame(width: metrics.iconSide * 0.75, height: metrics.iconSide * 0.75)
                }
                if group.apps.count > maxIcons {
                    Text("+\(group.apps.count - maxIcons)")
                        .font(.system(size: metrics.font(9))).foregroundStyle(.secondary)
                }
                Text("\(group.count)")
                    .font(.system(size: metrics.font(10), weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4).padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(group.helpText)
        .accessibilityLabel(group.helpText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
