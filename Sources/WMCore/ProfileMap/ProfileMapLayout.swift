import CoreGraphics
import Foundation

// Canvas geometry for the profile map (PM2). Turns a saved profile and the selected Space of each monitor
// into rectangles in canvas points, so the SwiftUI canvas only draws and hit-tests.
// Pure value math: no AppKit, no SwiftUI.
//
// Rules:
// - Monitors keep their real arrangement. Frames are scaled by one factor (fit to the viewport times zoom)
//   and shifted to one origin, so a monitor to the right stays to the right, and a shorter one stays lower or higher.
// - A monitor edge that touches another monitor gets `monitorGap / 2` inset, so touching tiles keep a 24 pt gap.
// - A tile is at least `minTileSize` on each side, so a tiny monitor stays readable.
// - Each tile has a Space strip band at its bottom with one thumbnail per Space of that display.
// - Windows are placed at `relativeFrame` inside the monitor's content rect (its visible frame), clamped to it.
//   A full-screen Space fills the content rect; a Split View Space gives each owner an equal part, left to right.

public struct ProfileMapLayout: Equatable, Sendable {
    /// Smallest tile side in canvas points.
    public static let minTileSize: CGFloat = 120
    /// Gap between two monitors that touch in the real arrangement.
    public static let monitorGap: CGFloat = 24
    /// Empty space around the monitors.
    public static let canvasMargin: CGFloat = 24
    /// Height of the Space strip band at the bottom of each monitor tile.
    public static let stripHeight: CGFloat = 32
    /// Inset of the strip band from the tile edges (sides and bottom).
    public static let stripInset: CGFloat = 8
    /// Band at the top of each monitor tile reserved for the monitor label; windows never draw there.
    public static let headerHeight: CGFloat = 22
    /// Allowed zoom factors: 50 % to 200 %. 1.0 means "fit".
    public static let zoomRange: ClosedRange<Double> = 0.5...2.0

    /// One monitor tile.
    public struct Monitor: Equatable, Sendable, Identifiable {
        /// `DisplayIdentity.uuid`.
        public var id: String
        public var name: String
        public var isMain: Bool
        /// The whole tile, canvas points.
        public var frame: CGRect
        /// The visible part of the monitor (no menu bar or Dock), inside `frame`. Window rects are relative to it.
        public var contentRect: CGRect
        /// Band at the bottom of the tile holding the Space thumbnails.
        public var stripRect: CGRect
    }

    /// One Space thumbnail in the strip of its monitor.
    public struct SpaceThumbnail: Equatable, Sendable, Identifiable {
        /// `ProfileSpaceIndex.Space.id`.
        public var id: String
        public var displayUUID: String
        public var rect: CGRect
        /// True when this Space is the one the monitor shows.
        public var isSelected: Bool
    }

    /// One window drawn on the selected Space of its monitor.
    public struct WindowTile: Equatable, Sendable, Identifiable {
        public var windowID: UUID
        /// The Space the window is drawn on.
        public var spaceID: String
        public var displayUUID: String
        public var rect: CGRect
        /// Stacking order, 0 = front. Hit testing picks the lowest value.
        public var zIndex: Int
        /// `WindowSnapshot.restore`: false draws the window hatched ("Not restored").
        public var isRestored: Bool
        /// The window is on all Desktops, so it is also drawn dashed on every other Desktop.
        public var isOnAllDesktops: Bool
        /// The window fills a full-screen Space.
        public var isFullScreen: Bool
        /// The window is one half of a Split View Space.
        public var isSplitHalf: Bool

        /// Unique per Space, since an "On all Desktops" window is drawn on several Spaces.
        public var id: String { "\(spaceID)#\(windowID.uuidString)" }
    }

    /// What a point on the canvas hits.
    public enum MapHit: Equatable, Sendable {
        case spaceThumbnail(spaceID: String)
        case window(windowID: UUID, spaceID: String)
        case monitor(displayUUID: String)
    }

    /// Canvas size in points. At least the viewport; larger when zoomed in, so the canvas scrolls.
    public let canvasSize: CGSize
    /// The zoom factor used, clamped to `zoomRange`.
    public let zoom: Double
    public let monitors: [Monitor]
    /// Thumbnails for every Space of every monitor.
    public let thumbnails: [SpaceThumbnail]
    /// Windows of the selected Space of each monitor, in drawing order (back to front).
    public let windows: [WindowTile]

    /// Empty layout, used when the profile has no monitors.
    public static func empty(viewport: CGSize) -> ProfileMapLayout {
        ProfileMapLayout(canvasSize: viewport, zoom: 1, monitors: [], thumbnails: [], windows: [])
    }

    init(canvasSize: CGSize, zoom: Double, monitors: [Monitor], thumbnails: [SpaceThumbnail], windows: [WindowTile]) {
        self.canvasSize = canvasSize
        self.zoom = zoom
        self.monitors = monitors
        self.thumbnails = thumbnails
        self.windows = windows
    }

    /// Lays out `profile` on a canvas.
    /// - Parameters:
    ///   - viewport: the visible size the fit uses; the canvas grows past it when zoomed in.
    ///   - selection: the selected Space id per display. A display missing here uses `index.defaultSpaceID`.
    ///   - zoom: 1.0 is fit, clamped to `zoomRange`.
    public static func make(profile: Profile, index: ProfileSpaceIndex, selection: [String: String] = [:],
                            viewport: CGSize, zoom: Double = 1) -> ProfileMapLayout {
        let zoomValue = min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
        let displays = profile.displays.filter { $0.frame.width > 0 && $0.frame.height > 0 }
        guard !displays.isEmpty else { return .empty(viewport: viewport) }

        let bounds = displays.dropFirst().reduce(displays[0].frame) { $0.union($1.frame) }
        let margin = canvasMargin
        let availableWidth = max(viewport.width - 2 * margin, 1)
        let availableHeight = max(viewport.height - 2 * margin, 1)
        let fitScale = min(availableWidth / bounds.width, availableHeight / bounds.height)
        let scale = fitScale * CGFloat(zoomValue)

        // Scaled tiles, with touching edges inset so neighbours keep a gap.
        var tiles: [CGRect] = []
        for (i, display) in displays.enumerated() {
            let touching = touchingSides(of: i, in: displays.map(\.frame))
            let frame = display.frame
            let x0 = margin + (frame.minX - bounds.minX) * scale
            let y0 = margin + (frame.minY - bounds.minY) * scale
            let half = monitorGap / 2
            let left = touching.left ? half : 0
            let right = touching.right ? half : 0
            let top = touching.top ? half : 0
            let bottom = touching.bottom ? half : 0
            var width = frame.width * scale - left - right
            var height = frame.height * scale - top - bottom
            width = max(width, minTileSize)
            height = max(height, minTileSize)
            tiles.append(CGRect(x: x0 + left, y: y0 + top, width: width, height: height))
        }

        var monitors: [Monitor] = []
        var thumbnails: [SpaceThumbnail] = []
        var windowTiles: [WindowTile] = []
        let windowsByID = Dictionary(profile.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (i, display) in displays.enumerated() {
            let tile = tiles[i]
            let content = contentRect(for: display, tile: tile)
            let strip = CGRect(x: tile.minX + stripInset, y: tile.maxY - stripHeight + stripInset / 2,
                               width: max(tile.width - 2 * stripInset, 0),
                               height: stripHeight - stripInset)
            monitors.append(Monitor(id: display.uuid, name: display.name, isMain: display.isMain,
                                    frame: tile, contentRect: content, stripRect: strip))

            // Strip thumbnails: one slot per Space, equal width.
            let spaces = index.spaces(onDisplay: display.uuid)
            let selectedID = selection[display.uuid] ?? index.defaultSpaceID(displayUUID: display.uuid)
            let slotGap: CGFloat = 4
            let slotWidth = spaces.isEmpty ? 0
                : max((strip.width - CGFloat(spaces.count - 1) * slotGap) / CGFloat(spaces.count), 0)
            for (slot, space) in spaces.enumerated() {
                let rect = CGRect(x: strip.minX + CGFloat(slot) * (slotWidth + slotGap), y: strip.minY,
                                  width: slotWidth, height: strip.height)
                thumbnails.append(SpaceThumbnail(id: space.id, displayUUID: display.uuid, rect: rect,
                                                 isSelected: space.id == selectedID))
            }

            // Windows of the selected Space only.
            guard let selectedID, let space = index.space(id: selectedID), space.displayUUID == display.uuid else {
                continue
            }
            let owners = space.windowIDs.compactMap { windowsByID[$0] }
            if space.kind == .fullScreen {
                // Owners fill the content rect, left to right by their saved position (equal parts for Split View).
                let sorted = owners.enumerated().sorted {
                    ($0.element.relativeFrame.minX, $0.offset) < ($1.element.relativeFrame.minX, $1.offset)
                }.map(\.element)
                let count = CGFloat(max(sorted.count, 1))
                for (slot, window) in sorted.enumerated() {
                    let rect = CGRect(x: content.minX + CGFloat(slot) * content.width / count, y: content.minY,
                                      width: content.width / count, height: content.height)
                    windowTiles.append(WindowTile(windowID: window.id, spaceID: space.id, displayUUID: display.uuid,
                                                  rect: rect, zIndex: window.zIndex, isRestored: window.restore,
                                                  isOnAllDesktops: false, isFullScreen: true,
                                                  isSplitHalf: sorted.count > 1))
                }
            } else {
                for window in owners {
                    let rect = windowRect(for: window, display: display, content: content)
                    windowTiles.append(WindowTile(windowID: window.id, spaceID: space.id, displayUUID: display.uuid,
                                                  rect: rect, zIndex: window.zIndex, isRestored: window.restore,
                                                  isOnAllDesktops: window.placement == .allDesktops,
                                                  isFullScreen: false, isSplitHalf: false))
                }
            }
        }

        let extentX = (tiles.map(\.maxX).max() ?? 0) + margin
        let extentY = (tiles.map(\.maxY).max() ?? 0) + margin
        let canvas = CGSize(width: max(viewport.width, extentX), height: max(viewport.height, extentY))
        return ProfileMapLayout(canvasSize: canvas, zoom: zoomValue, monitors: monitors,
                                thumbnails: thumbnails, windows: windowTiles)
    }

    /// The topmost item at `point`: a Space thumbnail, else a window (lowest `zIndex`), else a monitor tile.
    public func hitTest(_ point: CGPoint) -> MapHit? {
        if let thumb = thumbnails.last(where: { $0.rect.contains(point) }) {
            return .spaceThumbnail(spaceID: thumb.id)
        }
        var best: WindowTile?
        for window in windows where window.rect.contains(point) {
            if best == nil || window.zIndex < best!.zIndex { best = window }
        }
        if let best {
            return .window(windowID: best.windowID, spaceID: best.spaceID)
        }
        if let monitor = monitors.last(where: { $0.frame.contains(point) }) {
            return .monitor(displayUUID: monitor.id)
        }
        return nil
    }

    // MARK: Helpers

    /// The visible part of the display, inside its tile, using the same fractions as the real screen.
    private static func contentRect(for display: DisplayIdentity, tile fullTile: CGRect) -> CGRect {
        // Header band on top for the label, strip band at the bottom for the Space thumbnails: windows never draw there.
        let band = min(headerHeight, fullTile.height / 4)
        let bottomBand = min(stripHeight, fullTile.height / 4)
        let tile = CGRect(x: fullTile.minX, y: fullTile.minY + band, width: fullTile.width,
                          height: fullTile.height - band - bottomBand)
        let frame = display.frame
        let visible = display.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return tile }
        let fx = clamp01((visible.minX - frame.minX) / frame.width)
        let fy = clamp01((visible.minY - frame.minY) / frame.height)
        let fmaxX = clamp01((visible.maxX - frame.minX) / frame.width)
        let fmaxY = clamp01((visible.maxY - frame.minY) / frame.height)
        guard fmaxX > fx, fmaxY > fy else { return tile }
        return CGRect(x: tile.minX + fx * tile.width, y: tile.minY + fy * tile.height,
                      width: (fmaxX - fx) * tile.width, height: (fmaxY - fy) * tile.height)
    }

    /// A window's rect inside the content rect. Uses `relativeFrame` (fractions of the visible frame), or the
    /// frame when the relative one is empty. Clamped to the content rect.
    private static func windowRect(for window: WindowSnapshot, display: DisplayIdentity, content: CGRect) -> CGRect {
        var unit = unitRect(window.relativeFrame)
        if unit == nil, display.visibleFrame.width > 0, display.visibleFrame.height > 0 {
            let visible = display.visibleFrame
            unit = unitRect(CGRect(x: (window.frame.minX - visible.minX) / visible.width,
                                   y: (window.frame.minY - visible.minY) / visible.height,
                                   width: window.frame.width / visible.width,
                                   height: window.frame.height / visible.height))
        }
        guard let unit else {
            return CGRect(x: content.minX, y: content.minY, width: 0, height: 0)
        }
        return CGRect(x: content.minX + unit.minX * content.width, y: content.minY + unit.minY * content.height,
                      width: unit.width * content.width, height: unit.height * content.height)
    }

    /// Clamps a fractional rect to 0...1 on both axes. Nil when the result is empty or not finite.
    private static func unitRect(_ rect: CGRect) -> CGRect? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
        let x0 = clamp01(rect.minX)
        let y0 = clamp01(rect.minY)
        let x1 = clamp01(rect.maxX)
        let y1 = clamp01(rect.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private static func clamp01(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    /// Which sides of display `index` touch another display: the edges meet (within 1 pt) and the other edge
    /// overlaps. Touching sides are inset in the layout.
    private static func touchingSides(of index: Int, in frames: [CGRect]) -> (left: Bool, right: Bool, top: Bool, bottom: Bool) {
        let a = frames[index]
        var sides = (left: false, right: false, top: false, bottom: false)
        for (j, b) in frames.enumerated() where j != index {
            let verticalOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY) > 1
            let horizontalOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX) > 1
            if verticalOverlap {
                if abs(a.maxX - b.minX) <= 1 { sides.right = true }
                if abs(b.maxX - a.minX) <= 1 { sides.left = true }
            }
            if horizontalOverlap {
                if abs(a.maxY - b.minY) <= 1 { sides.bottom = true }
                if abs(b.maxY - a.minY) <= 1 { sides.top = true }
            }
        }
        return sides
    }
}
