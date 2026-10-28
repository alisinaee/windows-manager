import CoreGraphics
import Foundation

// Move the focused window to the next or previous display. Pure geometry: the app layer passes the visible
// frame of every display (global top-left coordinates) and the window frame, then sets the returned frame.

public enum DisplayMoveDirection: String, CaseIterable, Sendable {
    case next, previous
}

public enum DisplayMove {
    /// Index of the display the window belongs to: the one holding its centre, else the one it overlaps most.
    /// Nil when there are no displays.
    public static func displayIndex(of window: CGRect, in displays: [CGRect]) -> Int? {
        guard !displays.isEmpty else { return nil }
        let centre = CGPoint(x: window.midX, y: window.midY)
        if let index = displays.firstIndex(where: { $0.contains(centre) }) {
            return index
        }
        var best: (index: Int, area: CGFloat) = (0, 0)
        for (index, display) in displays.enumerated() {
            let overlap = display.intersection(window)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > best.area {
                best = (index, area)
            }
        }
        return best.index
    }

    /// Display order used for "next" and "previous": left to right, then top to bottom.
    public static func sortedOrder(of displays: [CGRect]) -> [Int] {
        displays.indices.sorted { a, b in
            let fa = displays[a], fb = displays[b]
            if fa.minX != fb.minX { return fa.minX < fb.minX }
            return fa.minY < fb.minY
        }
    }

    /// The window frame on the neighbouring display, or nil when there is no other display to move to.
    /// The window keeps its offset from the display's top-left corner and its size. Size shrinks only if the
    /// target display is smaller, and the result is clamped inside the target's visible frame.
    public static func targetFrame(current window: CGRect, displays: [CGRect],
                                   direction: DisplayMoveDirection) -> CGRect? {
        guard displays.count > 1, let from = displayIndex(of: window, in: displays) else { return nil }
        let order = sortedOrder(of: displays)
        guard let position = order.firstIndex(of: from) else { return nil }
        let step = direction == .next ? 1 : order.count - 1
        let to = displays[order[(position + step) % order.count]]
        let source = displays[from]

        let offsetX = window.minX - source.minX
        let offsetY = window.minY - source.minY
        let width = min(window.width, to.width)
        let height = min(window.height, to.height)
        let x = min(max(to.minX + offsetX, to.minX), to.maxX - width)
        let y = min(max(to.minY + offsetY, to.minY), to.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
