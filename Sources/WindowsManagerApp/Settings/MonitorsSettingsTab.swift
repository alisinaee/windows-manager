import SwiftUI
import WMCore

/// Read-only map of the connected displays, scaled to fit.
struct MonitorsSettingsTab: View {
    @StateObject private var model = MonitorsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.displays.isEmpty {
                Text("No displays found.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    map(in: geo.size)
                }
                .frame(maxHeight: .infinity)
            }
            HStack {
                Text("\(model.displays.count) display(s). The main display is marked with a star.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { model.refresh() }
            }
        }
        .padding()
        .onAppear { model.refresh() }
    }

    private func map(in size: CGSize) -> some View {
        let union = model.displays.dropFirst().reduce(model.displays[0].frame) { $0.union($1.frame) }
        let scale = min(size.width / max(union.width, 1), size.height / max(union.height, 1)) * 0.9
        let offsetX = (size.width - union.width * scale) / 2
        let offsetY = (size.height - union.height * scale) / 2
        return ZStack(alignment: .topLeading) {
            ForEach(model.displays, id: \.uuid) { display in
                let f = display.frame
                RoundedRectangle(cornerRadius: 4)
                    .fill(display.isMain ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(display.isMain ? Color.accentColor : Color.secondary))
                    .overlay(
                        VStack(spacing: 2) {
                            Text((display.isMain ? "\u{2605} " : "") + display.name).font(.caption.bold())
                            Text("\(Int(f.width)) x \(Int(f.height))").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(2)
                    )
                    .frame(width: f.width * scale, height: f.height * scale)
                    .offset(x: offsetX + (f.minX - union.minX) * scale, y: offsetY + (f.minY - union.minY) * scale)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

@MainActor
final class MonitorsModel: ObservableObject {
    @Published var displays: [DisplayIdentity] = DisplayMap.current()
    func refresh() { displays = DisplayMap.current() }
}
