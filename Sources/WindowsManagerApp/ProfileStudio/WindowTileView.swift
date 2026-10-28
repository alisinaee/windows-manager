import AppKit
import SwiftUI
import WMCore

/// App icons by bundle id, cached. Falls back to the generic application icon.
@MainActor
enum AppIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for app: AppRef) -> NSImage {
        let key = (app.bundleID ?? app.path ?? app.name) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var image: NSImage?
        if let id = app.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if let path = app.path, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        }
        let result = image ?? NSWorkspace.shared.icon(for: .applicationBundle)
        cache.setObject(result, forKey: key)
        return result
    }
}

/// Stable per-app tint: system colors only, so light and dark mode both work. Labels stay `.primary`.
enum AppTint {
    private static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown]

    static func color(for app: AppRef) -> Color {
        let text = app.bundleID ?? app.name
        var hash: UInt64 = 14695981039346656037   // FNV-1a, so the choice is stable across launches
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// Diagonal hatching, used for "Not restored".
struct HatchShape: Shape {
    var spacing: CGFloat = 7
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

/// The SF Symbol and short text of a window status. Status is never shown by color alone.
enum WindowStatusStyle {
    static func symbol(_ status: WindowLiveStatus) -> String {
        switch status {
        case .inPlace: return "checkmark.circle"
        case .willMove: return "arrow.left.arrow.right"
        case .willLaunch: return "arrow.up.forward.app"
        case .notFound: return "exclamationmark.triangle"
        case .notRestored: return "minus.circle"
        }
    }

    static func color(_ status: WindowLiveStatus) -> Color {
        switch status {
        case .inPlace: return .green
        case .willMove: return .blue
        case .willLaunch: return .purple
        case .notFound: return .orange
        case .notRestored: return .secondary
        }
    }
}

/// Text and icon sizes for the map at a zoom. The map is redrawn at its real size, so text stays legible
/// (never below 9pt, never gigantic) while strokes stay constant.
struct MapMetrics: Equatable {
    var zoom: CGFloat = 1

    func font(_ base: CGFloat) -> CGFloat { min(max(base * zoom, 9), 15) }
    var iconSide: CGFloat { min(max(16 * zoom, 12), 32) }
}

/// One window rectangle on the map. Size and position come from the parent; this view fills its frame.
struct WindowTileView: View {
    let window: WindowSnapshot
    let tile: ProfileMapLayout.WindowTile
    let status: WindowLiveStatus?
    let isSelected: Bool
    let isHovered: Bool
    var metrics = MapMetrics()
    /// How many windows overlap this one (1 = alone); the stack's badge is drawn by the parent.
    var stackCount = 1
    /// "Desktop 2 of Studio Display, window 3 of 6" style location text for VoiceOver.
    let locationText: String
    let onSelect: () -> Void
    let onHover: (Bool) -> Void

    private var tint: Color { AppTint.color(for: window.app) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: tile.isFullScreen ? 4 : 6, style: .continuous) }

    var body: some View {
        let size = tile.rect.size
        let roomy = size.width >= 80 && size.height >= 40
        ZStack(alignment: .topLeading) {
            shape.fill(tint.opacity(tile.isRestored ? 0.22 : 0.10))
            if !tile.isRestored {
                HatchShape().stroke(tint.opacity(0.4), lineWidth: 1).clipShape(shape)
            }
            shape.strokeBorder(tint.opacity(0.9),
                               style: StrokeStyle(lineWidth: tile.isFullScreen ? 2 : 1,
                                                  dash: tile.isOnAllDesktops ? [4, 3] : []))
            if isHovered && !isSelected {
                shape.strokeBorder(Color.primary.opacity(0.5), lineWidth: 2)
            }
            if isSelected {
                shape.strokeBorder(Color.accentColor, lineWidth: 3)
            }
            if min(size.width, size.height) >= 56 {
                let side = min(size.width, size.height) * 0.5
                Image(nsImage: AppIconCache.icon(for: window.app))
                    .resizable().interpolation(.high)
                    .frame(width: side, height: side)
                    .opacity(tile.isRestored ? 0.9 : 0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .accessibilityHidden(true)
            }
            label(roomy: roomy, width: size.width, height: size.height)
                .padding(.leading, 5).padding(.top, 5)
                .padding(.trailing, status == nil ? 5 : 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            if let status {
                Image(systemName: WindowStatusStyle.symbol(status))
                    .font(.system(size: metrics.font(12), weight: .semibold))
                    .foregroundStyle(WindowStatusStyle.color(status))
                    .padding(3)
                    .background(.regularMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(3)
            }
            if let message = window.resizeLimits?.fixedMessage, size.width >= 40, size.height >= 30 {
                Image(systemName: "lock.fill")
                    .font(.system(size: metrics.font(10), weight: .semibold))
                    .padding(3)
                    .background(.regularMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(4)
                    .help(message)
                    .accessibilityHidden(true)
            }
            if tile.isFullScreen && size.width >= 90 {
                Text(tile.isSplitHalf ? "Split View" : "Full screen")
                    .font(.system(size: metrics.font(11), weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(5)
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
        .contentShape(shape)
        .onTapGesture(perform: onSelect)
        .onHover(perform: onHover)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Select", onSelect)
    }

    @ViewBuilder private func label(roomy: Bool, width: CGFloat, height: CGFloat) -> some View {
        let fontSize = metrics.font((width < 120 || height < 56) ? 10 : 11)
        let showIcon = width >= 30 && height >= 26
        let hasTitle = !(window.title ?? "").isEmpty
        HStack(alignment: .top, spacing: 4) {
            if showIcon {
                Image(nsImage: AppIconCache.icon(for: window.app))
                    .resizable().frame(width: metrics.iconSide, height: metrics.iconSide)
            }
            if roomy {
                VStack(alignment: .leading, spacing: 0) {
                    Text(window.app.name).font(.system(size: fontSize, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                    if hasTitle, let title = window.title {
                        Text(title).font(.system(size: fontSize)).foregroundStyle(.secondary)
                            .lineLimit(height >= 80 ? 2 : 1).truncationMode(.tail)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private var helpText: String {
        var parts = [window.app.name]
        if let title = window.title, !title.isEmpty { parts.append("\"\(title)\"") }
        parts.append(locationText)
        if stackCount > 1 { parts.append("\(stackCount) windows overlap here") }
        let f = window.frame
        parts.append("\(Int(f.width))x\(Int(f.height)) at \(Int(f.minX)), \(Int(f.minY))")
        if let status { parts.append(ProfileMapModel.statusText(status)) }
        if let message = window.resizeLimits?.fixedMessage { parts.append(message) }
        return parts.joined(separator: " · ")
    }

    /// "Safari, window 'Docs', Desktop 2 of Display 1, 3 of 6, on the left half, will be moved"
    private var accessibilityText: String {
        var text = window.app.name
        if let title = window.title, !title.isEmpty { text += ", window '\(title)'" }
        text += ", \(locationText)"
        if stackCount > 1 { text += ", \(stackCount) windows overlap here" }
        if let phrase = ProfileMapModel.positionPhrase(for: window, tile: tile) {
            text += ", \(phrase)"
        }
        if tile.isOnAllDesktops { text += ", on all Desktops" }
        if let message = window.resizeLimits?.fixedMessage { text += ", " + message.lowercased() }
        if !tile.isRestored { text += ", not restored" }
        else if let status { text += ", " + ProfileMapModel.statusText(status) }
        return text
    }
}
