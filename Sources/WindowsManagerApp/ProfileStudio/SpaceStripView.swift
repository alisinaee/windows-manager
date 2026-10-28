import SwiftUI
import WMCore

/// The Space thumbnails of one monitor, placed at the rects `ProfileMapLayout` computed (canvas coordinates).
/// Desktops show a mini picture of their windows; a full-screen Space shows its app icon(s).
struct SpaceStripView: View {
    let thumbnails: [ProfileMapLayout.SpaceThumbnail]
    let index: ProfileSpaceIndex
    let windows: [UUID: WindowSnapshot]
    let spaceStatus: [SpaceKey: SpaceLiveStatus]
    let spaceName: (ProfileSpaceIndex.Space) -> String
    let onSelect: (String) -> Void
    var metrics = MapMetrics()

    var body: some View {
        ForEach(thumbnails) { thumb in
            if let space = index.space(id: thumb.id) {
                SpaceThumbnailView(space: space, rect: thumb.rect, isSelected: thumb.isSelected,
                                   windows: windows, missing: missingStatus(for: space),
                                   name: spaceName(space), metrics: metrics, onSelect: { onSelect(thumb.id) })
                    .offset(x: thumb.rect.minX, y: thumb.rect.minY)
            }
        }
    }

    private func missingStatus(for space: ProfileSpaceIndex.Space) -> SpaceLiveStatus? {
        guard space.kind == .desktop, let number = space.desktopNumber else { return nil }
        return spaceStatus[SpaceKey(displayUUID: space.displayUUID, desktopNumber: number)]
    }
}

struct SpaceThumbnailView: View {
    let space: ProfileSpaceIndex.Space
    let rect: CGRect
    let isSelected: Bool
    let windows: [UUID: WindowSnapshot]
    let missing: SpaceLiveStatus?
    let name: String
    var metrics = MapMetrics()
    let onSelect: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 4, style: .continuous) }

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                shape.fill(Color(nsColor: .windowBackgroundColor))
                miniPicture
                shape.strokeBorder(
                    isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: missing == nil ? [] : [3, 2]))
                HStack(spacing: 2) {
                    if space.kind == .fullScreen {
                        ForEach(space.fullScreenWindowIDs.prefix(2), id: \.self) { id in
                            if let window = windows[id] {
                                Image(nsImage: AppIconCache.icon(for: window.app)).resizable().frame(width: metrics.font(14), height: metrics.font(14))
                            }
                        }
                        if rect.width >= 70, let first = space.fullScreenWindowIDs.first.flatMap({ windows[$0] }) {
                            Text(first.app.name).font(.system(size: max(metrics.font(11), 11)))
                                .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    } else {
                        Text("D\(space.desktopNumber ?? space.position + 1)")
                            .font(.system(size: max(metrics.font(11), 11), weight: isSelected ? .bold : .regular))
                            .foregroundStyle(.primary)
                            .minimumScaleFactor(0.7).lineLimit(1)
                    }
                    if missing != nil {
                        Image(systemName: "circle.dashed").font(.system(size: max(metrics.font(10), 11))).foregroundStyle(.orange)
                    }
                }
            }
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Faint rectangles for the windows of a Desktop.
    @ViewBuilder private var miniPicture: some View {
        if space.kind == .desktop {
            GeometryReader { geo in
                ForEach(space.windowIDs, id: \.self) { id in
                    if let window = windows[id] {
                        let r = window.relativeFrame
                        Rectangle().fill(AppTint.color(for: window.app).opacity(0.25))
                            .frame(width: max(r.width * geo.size.width, 1), height: max(r.height * geo.size.height, 1))
                            .offset(x: r.minX * geo.size.width, y: r.minY * geo.size.height)
                    }
                }
            }
            .clipShape(shape)
            .accessibilityHidden(true)
        }
    }

    private var helpText: String {
        let count = space.windowIDs.count
        return "\(name), \(count) window\(count == 1 ? "" : "s")" + (missing == nil ? "" : ", Desktop missing now")
    }

    private var accessibilityText: String {
        helpText + (isSelected ? ", selected" : "")
    }
}
