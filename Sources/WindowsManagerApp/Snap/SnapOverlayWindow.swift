import AppKit
import SwiftUI
import WMCore

/// What the overlay draws: zone rectangles in the panel's own coordinates (origin top-left).
final class SnapOverlayModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: UUID
        var name: String
        var rect: CGRect
    }

    @Published var items: [Item] = []
    @Published var highlighted: UUID?
}

private struct SnapOverlayView: View {
    @ObservedObject var model: SnapOverlayModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.items) { item in
                let on = item.id == model.highlighted
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(on ? 0.40 : 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor.opacity(on ? 0.95 : 0.45), lineWidth: on ? 3 : 1.5)
                    )
                    .overlay(Text(item.name).font(.title3.weight(.medium)).foregroundColor(.white).opacity(on ? 1 : 0.7))
                    .frame(width: item.rect.width, height: item.rect.height)
                    .offset(x: item.rect.minX, y: item.rect.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.1), value: model.highlighted)
    }
}

/// A borderless, click-through panel covering one display.
final class SnapOverlayWindow: NSPanel {
    let model = SnapOverlayModel()
    /// Global top-left frame of the display this overlay covers (AX coordinates).
    private(set) var displayFrame: CGRect = .zero

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let host = NSHostingView(rootView: SnapOverlayView(model: model))
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
        displayFrame = SnapGeometry.topLeftFrame(of: screen.frame)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `layout` zones laid over `area` (global top-left coordinates, inside this display).
    func show(zonesOf layout: WMCore.Layout, in area: CGRect, highlighted: UUID?) {
        let dx = area.minX - displayFrame.minX
        let dy = area.minY - displayFrame.minY
        let items = layout.zones.map { zone -> SnapOverlayModel.Item in
            let r = LayoutGeometry.frame(of: zone, in: CGRect(x: dx, y: dy, width: area.width, height: area.height), gap: 4)
            return .init(id: zone.id, name: zone.name, rect: r)
        }
        if model.items != items { model.items = items }
        if model.highlighted != highlighted { model.highlighted = highlighted }
        if !isVisible { orderFrontRegardless() }
    }

    func hide() {
        orderOut(nil)
        model.items = []
        model.highlighted = nil
    }
}

enum SnapGeometry {
    /// Height of the primary display, the pivot between AppKit (bottom-left) and AX (top-left) coordinates.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func topLeftPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    static func topLeftFrame(of r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
