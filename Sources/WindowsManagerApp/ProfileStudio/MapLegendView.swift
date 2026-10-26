import SwiftUI
import WMCore

/// Legend of the symbols on the map. Status entries appear only when a live status is shown.
struct MapLegendView: View {
    let showsStatus: Bool

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
        [Entry(symbol: "rectangle.dashed", text: "On all Desktops (dashed)"),
         Entry(symbol: "line.3.horizontal.decrease", text: "Not restored (hatched)"),
         Entry(symbol: "arrow.up.left.and.arrow.down.right", text: "Full screen / Split View")]
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("Legend").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(shapeEntries) { item($0) }
            if showsStatus {
                Divider().frame(height: 12)
                ForEach(statusEntries) { item($0) }
            }
            Spacer(minLength: 0)
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
    }
}
