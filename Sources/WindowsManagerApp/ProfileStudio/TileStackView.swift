import SwiftUI
import WMCore

/// A collapsed stack of overlapping windows: the front tile with two "card edges" peeking out behind it. The badge
/// is drawn by `StackBadge` on top. Size and position come from the parent; this view fills the front tile's frame.
struct TileStackView<Front: View>: View {
    let size: CGSize
    let tint: Color
    /// Draw the edges only when the stack is collapsed; in Edit mode every window keeps its own tile.
    let showsEdges: Bool
    @ViewBuilder let front: () -> Front

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsEdges {
                ForEach([2, 1], id: \.self) { depth in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(tint.opacity(0.7), lineWidth: 1))
                        .frame(width: max(size.width, 1), height: max(size.height, 1))
                        .offset(x: CGFloat(depth) * 5, y: CGFloat(depth) * 5)
                        .accessibilityHidden(true)
                }
            }
            front()
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)
    }
}

/// A window stacked behind another in Edit mode (every tile is kept there). Only a dashed outline is drawn, with no
/// label, so its title does not print over the top tile's. The top tile carries the label and the "×N" badge.
struct StackedBehindTile: View {
    let size: CGSize
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The "×N" badge of a stack. A button in View mode and Compare (cycles the front window), a plain hint in Edit mode.
struct StackBadge: View {
    let stack: TileStacking.Stack
    let appName: String
    let metrics: MapMetrics
    let isInteractive: Bool
    let onCycle: () -> Void

    private var label: String { "\(appName) \u{00D7}\(stack.count): \(stack.count) windows overlap here" }

    var body: some View {
        let badge = Label("\(stack.count) windows", systemImage: "square.stack.3d.down.right")
            .labelStyle(.titleAndIcon)
            .font(.system(size: metrics.font(11), weight: .bold)).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
        Group {
            if isInteractive {
                Button(action: onCycle) { badge }
                    .buttonStyle(.plain)
                    .help("\(label). Click to bring the next window to the front")
                    .accessibilityLabel(label)
                    .accessibilityHint("Brings the next window to the front")
            } else {
                badge
                    .help(label).accessibilityLabel(label)
                    .allowsHitTesting(false)
            }
        }
        .padding(5)
    }
}

/// The strip of cards that fans a stack's windows out below (else above) the front tile.
struct StackFanView: View {
    let stack: TileStacking.Stack
    /// Members, front first.
    let windows: [WindowSnapshot]
    let selectedID: UUID?
    /// The front tile, and the monitor the strip must stay inside (both in the zoomed canvas).
    let anchor: CGRect
    let bounds: CGRect
    let metrics: MapMetrics
    let onSelect: (UUID) -> Void

    private let cardHeight: CGFloat = 36
    private let spacing: CGFloat = 4

    var body: some View {
        let count = max(windows.count, 1)
        let width = min(140, max(56, (bounds.width - 8 - spacing * CGFloat(count - 1)) / CGFloat(count)))
        let total = width * CGFloat(count) + spacing * CGFloat(count - 1)
        let x = min(max(anchor.minX, bounds.minX + 4), max(bounds.maxX - total - 4, bounds.minX + 4))
        var y = anchor.maxY + 14
        if y + cardHeight > bounds.maxY { y = anchor.minY - cardHeight - 6 }
        if y < bounds.minY { y = max(bounds.maxY - cardHeight - 4, bounds.minY) }
        return HStack(spacing: spacing) {
            ForEach(Array(windows.enumerated()), id: \.element.id) { at, window in
                card(window, position: at + 1, width: width)
            }
        }
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .offset(x: x - 2, y: y - 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(windows.first?.app.name ?? "Windows") \u{00D7}\(stack.count): \(stack.count) windows overlap here")
    }

    private func card(_ window: WindowSnapshot, position: Int, width: CGFloat) -> some View {
        let selected = window.id == selectedID
        let title = (window.title ?? "").isEmpty ? window.app.name : window.title!
        let tint = AppTint.color(for: window.app)
        return Button { onSelect(window.id) } label: {
            HStack(spacing: 4) {
                Image(nsImage: AppIconCache.icon(for: window.app)).resizable().frame(width: 16, height: 16)
                Text(title).font(.system(size: metrics.font(10))).lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 5)
            .frame(width: width, height: cardHeight)
            .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : tint.opacity(0.8), lineWidth: selected ? 3 : 1))
        }
        .buttonStyle(.plain)
        .help("\(window.app.name) \"\(window.title ?? "")\": window \(position) of \(stack.count). Click to bring to the front")
        .accessibilityLabel("\(window.app.name)" + ((window.title ?? "").isEmpty ? "" : ", window '\(window.title!)'")
                            + ", \(position) of \(stack.count) overlapping")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
