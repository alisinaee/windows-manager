import CoreGraphics
import Foundation

// Auto layout (G4): arranges the tiles of one Desktop on one monitor by the number and kind of apps.
// Pure value math on canvas rects (real screen points). `candidates` returns 1-3 layouts, best first.

public enum AutoLayout {
    /// Gap between neighbouring tiles, canvas points.
    public static let defaultGap: CGFloat = 8

    /// What an app is for: a main app gets the big area, a utility app the small one.
    public enum Kind: Sendable { case main, utility, other }

    public struct Item: Equatable, Sendable {
        public var id: UUID
        public var bundleID: String?
        public init(id: UUID, bundleID: String?) { self.id = id; self.bundleID = bundleID }
    }

    public struct Candidate: Equatable, Sendable {
        public var name: String
        public var frames: [UUID: CGRect]
    }

    private static let mainPrefixes = [
        "com.apple.dt.xcode", "com.microsoft.vscode", "com.sublimetext", "com.jetbrains.", "dev.zed", "com.todesktop.",
        "com.apple.safari", "com.google.chrome", "org.mozilla.firefox", "company.thebrowser", "com.microsoft.edgemac",
        "com.brave.browser", "com.figma", "com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
    ]
    private static let utilityPrefixes = [
        "com.tinyspeck.slackmacgap", "com.hnc.discord", "com.apple.mobilesms", "ru.keepcoder.telegram", "net.whatsapp",
        "com.apple.mail", "com.spotify", "com.apple.music", "com.apple.notes", "com.apple.ical", "com.apple.reminders",
        "com.apple.stickies", "com.apple.calculator", "us.zoom", "com.microsoft.teams",
    ]

    public static func kind(ofBundleID id: String?) -> Kind {
        guard let id = id?.lowercased() else { return .other }
        if mainPrefixes.contains(where: { id.hasPrefix($0) }) { return .main }
        if utilityPrefixes.contains(where: { id.hasPrefix($0) }) { return .utility }
        return .other
    }

    /// Candidate layouts for `items` inside `visible`, best first (empty for no items).
    public static func candidates(items: [Item], visible: CGRect, gap: CGFloat = defaultGap) -> [Candidate] {
        guard !items.isEmpty, visible.width > 0, visible.height > 0 else { return [] }
        let g = max(gap, 0)
        // Main apps first, utilities last; otherwise the given order.
        let rank: (Item) -> Int = { switch kind(ofBundleID: $0.bundleID) { case .main: return 0; case .other: return 1; case .utility: return 2 } }
        let ordered = items.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        let ids = ordered.map(\.id)
        let n = ids.count

        func make(_ name: String, _ rects: [CGRect]) -> Candidate {
            Candidate(name: name, frames: Dictionary(uniqueKeysWithValues: zip(ids, rects)))
        }
        switch n {
        case 1:
            return [make("Full", [visible])]
        case 2:
            let mainUtility = kind(ofBundleID: ordered[0].bundleID) == .main && kind(ofBundleID: ordered[1].bundleID) == .utility
            let halves = make("Halves", split(visible, axis: .horizontal, weights: [1, 1], gap: g))
            let twoThirds = make("Main 2/3 + side 1/3", split(visible, axis: .horizontal, weights: [2, 1], gap: g))
            let stacked = make("Stacked", split(visible, axis: .vertical, weights: [1, 1], gap: g))
            return mainUtility ? [twoThirds, halves, stacked] : [halves, twoThirds, stacked]
        case 3:
            let cols = split(visible, axis: .horizontal, weights: [3, 2], gap: g)
            let right = split(cols[1], axis: .vertical, weights: [1, 1], gap: g)
            let rows = split(visible, axis: .vertical, weights: [3, 2], gap: g)
            let bottom = split(rows[1], axis: .horizontal, weights: [1, 1], gap: g)
            return [make("Main left + 2 right", [cols[0], right[0], right[1]]),
                    make("Main top + 2 below", [rows[0], bottom[0], bottom[1]]),
                    make("3 columns", split(visible, axis: .horizontal, weights: [1, 1, 1], gap: g))]
        case 4:
            let quads = grid(visible, count: 4, columns: 2, gap: g)
            let cols = split(visible, axis: .horizontal, weights: [3, 2], gap: g)
            let right = split(cols[1], axis: .vertical, weights: [1, 1, 1], gap: g)
            return [make("Quadrants", quads),
                    make("Main left + 3 right", [cols[0]] + right),
                    make("4 columns", split(visible, axis: .horizontal, weights: [1, 1, 1, 1], gap: g))]
        default:
            let columns = Int((Double(n) * Double(visible.width / visible.height)).squareRoot().rounded())
            let c = min(max(columns, 1), n)
            let cols = split(visible, axis: .horizontal, weights: [1, 1], gap: g)
            let rest = grid(cols[1], count: n - 1, columns: max(1, Int(Double(n - 1).squareRoot().rounded())), gap: g)
            return [make("Grid", grid(visible, count: n, columns: c, gap: g)),
                    make("Main left + grid", [cols[0]] + rest)]
        }
    }

    enum Axis { case horizontal, vertical }

    /// Splits `rect` into pieces by weight along `axis` (horizontal = side by side), `gap` between them.
    static func split(_ rect: CGRect, axis: Axis, weights: [CGFloat], gap: CGFloat) -> [CGRect] {
        let total = axis == .horizontal ? rect.width : rect.height
        let usable = max(total - gap * CGFloat(weights.count - 1), 0)
        let sum = weights.reduce(0, +)
        var pos = axis == .horizontal ? rect.minX : rect.minY
        return weights.map { w in
            let len = usable * w / sum
            defer { pos += len + gap }
            return axis == .horizontal ? CGRect(x: pos, y: rect.minY, width: len, height: rect.height)
                                       : CGRect(x: rect.minX, y: pos, width: rect.width, height: len)
        }
    }

    /// `count` cells in `columns` columns, row by row; the last row's cells are widened to fill it.
    static func grid(_ rect: CGRect, count: Int, columns: Int, gap: CGFloat) -> [CGRect] {
        let rows = (count + columns - 1) / columns
        let rowRects = split(rect, axis: .vertical, weights: Array(repeating: 1, count: rows), gap: gap)
        var out: [CGRect] = []
        for (r, row) in rowRects.enumerated() {
            let inRow = min(columns, count - r * columns)
            out += split(row, axis: .horizontal, weights: Array(repeating: 1, count: inRow), gap: gap)
        }
        return out
    }
}
