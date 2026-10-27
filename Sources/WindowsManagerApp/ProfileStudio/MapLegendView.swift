import SwiftUI
import WMCore

/// Legend of the symbols on the map. Status entries appear only when a live status is shown.
struct MapLegendView: View {
    let showsStatus: Bool
    /// True when the profile was captured with Stage Manager on: adds the strip entry (P6.58).
    var showsStageStrip = false

    private struct Entry: Identifiable {
        let symbol: String
        let text: String
        var id: String { text }
    }

    private var statusEntries: [Entry] {
        [Entry(symbol: "checkmark.circle", text: "In place"),
         Entry(symbol: "arrow.left.arrow.right", text: "Will move"),
         Entry(symbol: "arrow.up.forward.app", text: "App will launch"),
         Entry(symbol: "exclamationmark.triangle", text: "Not found"),
         Entry(symbol: "circle.dashed", text: "Desktop missing")]
    }

    private var shapeEntries: [Entry] {
        var entries = [Entry(symbol: "rectangle.dashed", text: "All Desktops (dashed)"),
                       Entry(symbol: "line.3.horizontal.decrease", text: "Not restored (hatched)"),
                       Entry(symbol: "arrow.up.left.and.arrow.down.right", text: "Full screen / Split")]
        if showsStageStrip { entries.append(Entry(symbol: "sidebar.left", text: "Stage Manager strip")) }
        return entries
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Legend").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            LegendFlow(spacing: 14, lineSpacing: 4) {
                ForEach(shapeEntries + (showsStatus ? statusEntries : [])) { item($0) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Legend: " + (shapeEntries + (showsStatus ? statusEntries : [])).map(\.text).joined(separator: ", "))
    }

    private func item(_ entry: Entry) -> some View {
        HStack(spacing: 4) {
            Image(systemName: entry.symbol).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(entry.text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Left-to-right flow that wraps onto further lines when the width runs out.
private struct LegendFlow: SwiftUI.Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + lineSpacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
