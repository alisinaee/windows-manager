import CoreGraphics
import Foundation

/// Pure rules for learning what size an app accepts from what it did when a frame was set.
/// Some apps take the AXSize write but clamp it; the position is right and only the size differs.
public enum SizeLimitLearning {
    public enum Classification: Equatable, Sendable {
        /// Position and size are where they were asked.
        case matched
        /// Position is right, the app kept another size (`actual`).
        case sizeClamped(actual: CGSize)
        /// The window is not where it was asked to be, or the frame could not be read.
        case positionOff
    }

    public static func classify(requested: CGRect, actual: CGRect?, sizeTolerance: CGFloat = 1,
                                positionTolerance: CGFloat = 2) -> Classification {
        guard let actual else { return .positionOff }
        guard WindowMover.positionMatches(actual.origin, requested.origin, tolerance: positionTolerance) else {
            return .positionOff
        }
        if WindowMover.sizeMatches(actual.size, requested.size, tolerance: sizeTolerance) { return .matched }
        return .sizeClamped(actual: actual.size)
    }

    /// "app limits size to 740x893".
    public static func note(for size: CGSize) -> String {
        "app limits size to \(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    /// Limits shown by one clamped write. `previous` is the window size before the write.
    /// An axis that did not follow the request and kept its previous extent is fixed; otherwise the observed
    /// extent is the maximum (the app would not grow) or the minimum (it would not shrink). Nil when nothing was learned.
    public static func learn(requested: CGSize, observed: CGSize, previous: CGSize?,
                             tolerance: CGFloat = 1) -> WindowResizeLimits? {
        var limits = WindowResizeLimits()
        func axis(_ want: CGFloat, _ got: CGFloat, _ prev: CGFloat?) -> (fixed: Bool, min: CGFloat?, max: CGFloat?) {
            guard abs(got - want) > tolerance else { return (false, nil, nil) }
            if let prev, abs(got - prev) <= tolerance { return (true, nil, nil) }
            return got < want ? (false, nil, got) : (false, got, nil)
        }
        let w = axis(requested.width, observed.width, previous?.width)
        let h = axis(requested.height, observed.height, previous?.height)
        limits.fixedWidth = w.fixed
        limits.fixedHeight = h.fixed
        if w.min != nil || h.min != nil { limits.minSize = CGSize(width: w.min ?? 0, height: h.min ?? 0) }
        if w.max != nil || h.max != nil {
            limits.maxSize = CGSize(width: w.max ?? .greatestFiniteMagnitude, height: h.max ?? .greatestFiniteMagnitude)
        }
        return limits.hasRestrictions ? limits : nil
    }

    /// `learned` added to `existing`: fixed flags are kept, minimums grow, maximums shrink. Never loses a known limit.
    public static func merge(_ existing: WindowResizeLimits?, with learned: WindowResizeLimits?) -> WindowResizeLimits? {
        guard let learned else { return existing }
        guard var out = existing else { return learned }
        out.fixedWidth = out.fixedWidth || learned.fixedWidth
        out.fixedHeight = out.fixedHeight || learned.fixedHeight
        out.canMove = out.canMove && learned.canMove
        out.probed = out.probed || learned.probed
        out.minSize = combine(out.minSize, learned.minSize, empty: 0) { Swift.max($0, $1) }
        out.maxSize = combine(out.maxSize, learned.maxSize, empty: .greatestFiniteMagnitude) { Swift.min($0, $1) }
        return out
    }

    private static func combine(_ a: CGSize?, _ b: CGSize?, empty: CGFloat,
                                _ pick: (CGFloat, CGFloat) -> CGFloat) -> CGSize? {
        guard let a else { return b }
        guard let b else { return a }
        return CGSize(width: pick(a.width, b.width), height: pick(a.height, b.height))
    }

    /// True when `merged` knows something `existing` did not.
    public static func adds(_ merged: WindowResizeLimits?, to existing: WindowResizeLimits?) -> Bool {
        merged != nil && merged != existing
    }

    /// The window's own limits merged with what the store learned or probed for its app and title kind.
    public static func effectiveLimits(for window: LiveWindow, store: SizeLimitStore = .shared) -> WindowResizeLimits? {
        effectiveLimits(own: window.resizeLimits, bundleID: window.app.bundleID, title: window.title, store: store)
    }

    public static func effectiveLimits(for window: WindowSnapshot, store: SizeLimitStore = .shared) -> WindowResizeLimits? {
        effectiveLimits(own: window.resizeLimits, bundleID: window.app.bundleID, title: window.title, store: store)
    }

    public static func effectiveLimits(own: WindowResizeLimits?, bundleID: String?, title: String?,
                                       store: SizeLimitStore = .shared) -> WindowResizeLimits? {
        merge(own, with: store.limits(bundleID: bundleID, title: title))
    }

    /// A stable kind for a window title: lowercase, digits and extra spaces removed. Empty for no title.
    public static func titleKind(_ title: String?) -> String {
        guard let title else { return "" }
        let kept = title.lowercased().filter { !$0.isNumber }
        return kept.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Limits learned per app (bundle id) and window title kind, kept in
/// `~/Library/Application Support/WindowsManager/size-limits.json`.
public final class SizeLimitStore: @unchecked Sendable {
    public static var defaultFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("WindowsManager", isDirectory: true)
            .appendingPathComponent("size-limits.json", isDirectory: false)
    }

    public static let shared = SizeLimitStore()

    public let file: URL
    private let lock = NSLock()

    public init(file: URL? = nil) { self.file = file ?? Self.defaultFile }

    private func key(_ bundleID: String, _ title: String?) -> String {
        "\(bundleID.lowercased())|\(SizeLimitLearning.titleKind(title))"
    }

    private func read() -> [String: WindowResizeLimits] {
        guard let data = try? Data(contentsOf: file),
              let map = try? JSONDecoder().decode([String: WindowResizeLimits].self, from: data) else { return [:] }
        return map
    }

    /// Limits for the app and title kind; falls back to the app's untitled entry.
    public func limits(bundleID: String?, title: String?) -> WindowResizeLimits? {
        guard let bundleID else { return nil }
        lock.lock(); defer { lock.unlock() }
        let map = read()
        return map[key(bundleID, title)] ?? map[key(bundleID, nil)]
    }

    /// True when nothing is known for this exact app and title kind (no learned limits, no earlier probe).
    public func needsProbe(bundleID: String?, title: String?) -> Bool {
        guard let bundleID else { return false }
        lock.lock(); defer { lock.unlock() }
        return read()[key(bundleID, title)] == nil
    }

    /// Merges `learned` into the entry. Returns the stored limits, or nil when nothing was written.
    @discardableResult
    public func record(_ learned: WindowResizeLimits, bundleID: String?, title: String?) -> WindowResizeLimits? {
        guard let bundleID else { return nil }
        lock.lock(); defer { lock.unlock() }
        var map = read()
        let k = key(bundleID, title)
        guard let merged = SizeLimitLearning.merge(map[k], with: learned) else { return nil }
        guard merged != map[k] else { return merged }
        map[k] = merged
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(map) else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return merged
    }
}
