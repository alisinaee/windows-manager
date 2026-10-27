import CoreGraphics
import Foundation

/// Groups window tiles that sit on top of each other (three Terminal windows at nearly the same spot) so the map can
/// draw them as one stack instead of unreadable overlapping text. Pure geometry, no UI.
///
/// Rules, per Space:
/// - Two windows overlap when their intersection over union (IoU) of the frames is at least `sameAppThreshold`
///   (0.8). IoU, not intersection over the smaller area: a small window inside a big one of the same app is not
///   hidden by it, it is a different window.
/// - Windows of different apps only stack when their frames are practically identical (IoU >= `identicalThreshold`).
/// - A window joins the first stack whose front window it matches. Comparing against the front only (never
///   chaining through other members) keeps a slowly drifting row of windows from collapsing into one stack.
public enum TileStacking {
    public static let sameAppThreshold: CGFloat = 0.8
    public static let identicalThreshold: CGFloat = 0.98

    /// One window tile as the grouping sees it.
    public struct Item: Equatable, Sendable {
        public var windowID: UUID
        public var spaceID: String
        public var rect: CGRect
        /// Stacking order, 0 = front.
        public var zIndex: Int
        /// Same value = same app (bundle id, else name).
        public var appKey: String

        public init(windowID: UUID, spaceID: String, rect: CGRect, zIndex: Int, appKey: String) {
            self.windowID = windowID
            self.spaceID = spaceID
            self.rect = rect
            self.zIndex = zIndex
            self.appKey = appKey
        }
    }

    /// Windows that overlap, front-most first. A lone window is a stack of one.
    public struct Stack: Equatable, Sendable, Identifiable {
        public var spaceID: String
        public var members: [UUID]
        public var appKey: String
        public var count: Int { members.count }
        public var isStack: Bool { members.count > 1 }
        /// Stable while the members stay the same, so "which window is in front" can be remembered against it.
        public var id: String { "\(spaceID)#" + (members.map(\.uuidString).min() ?? "") }
    }

    /// Stacks ordered by their front window (front-most first); ties keep the input order. Members are ordered by
    /// `zIndex`, ties again by input order, so the result never depends on dictionary or hash order.
    public static func group(_ items: [Item]) -> [Stack] {
        let order = items.indices.sorted { a, b in
            items[a].zIndex != items[b].zIndex ? items[a].zIndex < items[b].zIndex : a < b
        }
        var stacks: [(front: Item, stack: Stack)] = []
        for at in order {
            let item = items[at]
            if let slot = stacks.firstIndex(where: { $0.stack.spaceID == item.spaceID && matches($0.front, item) }) {
                if !stacks[slot].stack.members.contains(item.windowID) { stacks[slot].stack.members.append(item.windowID) }
            } else {
                stacks.append((item, Stack(spaceID: item.spaceID, members: [item.windowID], appKey: item.appKey)))
            }
        }
        return stacks.map(\.stack)
    }

    /// Intersection area over union area, 0 for empty frames.
    public static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }

    static func matches(_ a: Item, _ b: Item) -> Bool {
        let overlap = iou(a.rect, b.rect)
        return overlap >= (a.appKey == b.appKey ? sameAppThreshold : identicalThreshold)
    }
}
