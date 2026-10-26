import CoreGraphics
import Foundation

// The window matcher (phase P2.6): decides which live window is which saved window, so a restore moves
// the right window. Two windows of one app (two Chrome windows, two full-screen VS Code windows) must not
// be swapped, so the matcher scores every (saved window, live window) pair of the same app and picks the
// assignment with the best total score, not the first plausible window.
//
// Pure functions over plain data (`WindowSnapshot`, `LiveWindow`); nothing here talks to the system.

/// Why a pair of windows scored the way it did.
public enum MatchReason: String, Hashable, Sendable, CaseIterable {
    /// The saved window has a title rule (exact / contains / regex) and the live title passes it.
    case userRule
    /// Same document path.
    case documentPath
    /// Both windows show a document, and not the same one (counts against the pair).
    case documentPathDiffers
    /// The titles are equal after normalization.
    case titleEqual
    /// The titles share most of their words.
    case titleSimilar
    /// Both windows are full-screen, or both are not.
    case fullScreen
    /// Same display.
    case display
    /// The frames are close.
    case frame
    /// Same position among the app's windows.
    case indexInApp
    /// The saved window has a title rule and the live title fails it, so the pair is impossible.
    case ruleFailed
}

/// How well one live window fits one saved window.
public struct MatchScore: Hashable, Sendable {
    /// Sum of the points of all reasons (higher is better). Meaningless when `isPossible` is false.
    public var total: Int
    public var reasons: [MatchReason]
    /// False when a user title rule rules this live window out: the pair must never be assigned.
    public var isPossible: Bool

    public init(total: Int, reasons: [MatchReason], isPossible: Bool = true) {
        self.total = total
        self.reasons = reasons
        self.isPossible = isPossible
    }

    /// The score of a pair that must not be assigned.
    public static let impossible = MatchScore(total: 0, reasons: [.ruleFailed], isPossible: false)
}

/// One saved window paired with the live window that will be restored into it.
public struct Match: Hashable, Sendable, Identifiable {
    /// `WindowSnapshot.id`.
    public var snapshotID: UUID
    /// `LiveWindow.windowID`.
    public var windowID: UInt32
    public var score: MatchScore

    public var reasons: [MatchReason] { score.reasons }
    public var id: UUID { snapshotID }

    public init(snapshotID: UUID, windowID: UInt32, score: MatchScore) {
        self.snapshotID = snapshotID
        self.windowID = windowID
        self.score = score
    }
}

/// The outcome of matching a profile's windows against the windows that exist now.
public struct MatchResult: Hashable, Sendable {
    /// Saved windows that found a live window, in the order of the input snapshots.
    public var matched: [Match]
    /// Saved windows (with `restore == true`) without a live window: the app is closed or has fewer windows
    /// open than the profile. The restore has to open them.
    public var missing: [WindowSnapshot]
    /// Live windows that no saved window claimed: other apps, or more windows than the profile has
    /// (windows of snapshots with `restore == false` are in here too).
    public var extra: [LiveWindow]
    /// `WindowSnapshot.id` of matched saved windows where the choice was close to a coin flip, so the UI can warn.
    public var ambiguous: [UUID]

    public init(matched: [Match] = [], missing: [WindowSnapshot] = [], extra: [LiveWindow] = [],
                ambiguous: [UUID] = []) {
        self.matched = matched
        self.missing = missing
        self.extra = extra
        self.ambiguous = ambiguous
    }
}

public enum WindowMatcher {
    // MARK: Tuning

    /// Points per piece of evidence. A document path outranks any title; a title outranks position;
    /// `indexInApp` only breaks ties.
    public enum Weights {
        /// Same document path.
        public static let documentPath = 1000
        /// Both windows show a document and they differ (subtracted).
        public static let documentPathDiffers = 250
        /// A user title rule is set and passes (a failing rule makes the pair impossible instead).
        public static let userRule = 500
        /// Titles equal after normalization.
        public static let titleEqual = 600
        /// Title similarity (word overlap, 0...1) is multiplied by this.
        public static let titleSimilarMax = 400
        /// Similarity below this counts for nothing.
        public static let minTitleSimilarity = 0.3
        /// Same full-screen state.
        public static let fullScreen = 150
        /// Same display.
        public static let display = 100
        /// Identical frames; fades out linearly with the distance.
        public static let frameMax = 200
        /// Mean distance in points of the four edges at which the frame gives no points.
        public static let frameFalloff = 1000.0
        /// A frame at least this good is listed as a reason (half of `frameMax`).
        public static let frameReasonMin = 100
        /// Same `indexInApp`.
        public static let indexInApp = 50
    }

    /// Best and second-best candidates closer than this many points make a match ambiguous.
    public static let ambiguityMargin = 100

    /// Up to this many windows per app the best assignment is found by exhaustive search; above it
    /// the matcher picks pairs greedily by score.
    public static let exhaustiveLimit = 8

    // MARK: Titles

    /// A title reduced to what identifies the window: lower case, without a leading unread counter
    /// ("(3) ", "[12] ", "(99+) ") or unsaved-changes marker ("● ", "• "), without a trailing " — App" /
    /// " - App" when `appName` is given, with runs of whitespace collapsed to one space.
    public static func normalizeTitle(_ title: String, appName: String? = nil) -> String {
        var text = collapseWhitespace(title.lowercased())
        text = String(stripLeadingMarkers(Substring(text)))
        text = collapseWhitespace(text)
        if let app = appName.map({ collapseWhitespace($0.lowercased()) }), !app.isEmpty {
            for separator in [" \u{2014} ", " \u{2013} ", " - "] {
                let suffix = separator + app
                if text.hasSuffix(suffix), text.count > suffix.count {
                    text.removeLast(suffix.count)
                    break
                }
            }
        }
        return text
    }

    /// Does the live title satisfy the user's title rule? `.any` always does; the other rules need a title
    /// (a nil title cannot be checked, so it fails). `.exact` compares normalized titles, `.contains` ignores
    /// case and whitespace runs (and also tries the normalized forms), `.regex` searches the raw title
    /// (case-sensitive unless the pattern says `(?i)`; an invalid pattern never matches).
    public static func titleSatisfies(_ match: TitleMatch, _ title: String?, appName: String? = nil) -> Bool {
        TitleRule(match).isSatisfied(by: title, appName: appName)
    }

    // MARK: Scoring

    /// How well `live` fits `snapshot`. The app is not compared here (`match` groups by app first).
    public static func score(snapshot: WindowSnapshot, live: LiveWindow) -> MatchScore {
        score(snapshot: snapshot, live: live, rule: TitleRule(snapshot.titleMatch))
    }

    private static func score(snapshot: WindowSnapshot, live: LiveWindow, rule: TitleRule) -> MatchScore {
        // A user rule is a hard condition, not a preference.
        guard rule.isSatisfied(by: live.title, appName: live.app.name) else { return .impossible }

        var total = 0
        var reasons: [MatchReason] = []
        func add(_ points: Int, _ reason: MatchReason) {
            total += points
            reasons.append(reason)
        }

        if snapshot.titleMatch != .any { add(Weights.userRule, .userRule) }

        if let saved = normalizeDocumentPath(snapshot.documentPath), let current = normalizeDocumentPath(live.documentPath) {
            if saved == current {
                add(Weights.documentPath, .documentPath)
            } else {
                add(-Weights.documentPathDiffers, .documentPathDiffers)
            }
        }

        let savedTitle = snapshot.title.map { normalizeTitle($0, appName: snapshot.app.name) } ?? ""
        let liveTitle = live.title.map { normalizeTitle($0, appName: live.app.name) } ?? ""
        if !savedTitle.isEmpty, !liveTitle.isEmpty {
            if savedTitle == liveTitle {
                add(Weights.titleEqual, .titleEqual)
            } else {
                let similarity = tokenSimilarity(savedTitle, liveTitle)
                if similarity >= Weights.minTitleSimilarity {
                    add(Int((Double(Weights.titleSimilarMax) * similarity).rounded()), .titleSimilar)
                }
            }
        }

        if snapshot.isFullScreen == live.isFullScreen { add(Weights.fullScreen, .fullScreen) }

        if let saved = snapshot.displayUUID.nonEmpty, let current = live.displayUUID?.nonEmpty,
           saved.caseInsensitiveCompare(current) == .orderedSame {
            add(Weights.display, .display)
        }

        let framePoints = frameScore(snapshot.frame, live.frame)
        if framePoints > 0 {
            total += framePoints
            if framePoints >= Weights.frameReasonMin { reasons.append(.frame) }
        }

        if snapshot.indexInApp == live.indexInApp { add(Weights.indexInApp, .indexInApp) }

        return MatchScore(total: total, reasons: reasons, isPossible: true)
    }

    // MARK: Matching

    /// Matches saved windows to live windows. Windows are grouped by app (bundle id, otherwise name, ignoring
    /// case); inside each app the assignment with the most matched windows and then the highest total score
    /// wins (exhaustive search up to `exhaustiveLimit` windows, greedy by score above that). A live window is
    /// never assigned twice, and ties are resolved by `indexInApp` and window id, so the result does not depend
    /// on the order of the input arrays. Snapshots with `restore == false` are ignored.
    public static func match(snapshots: [WindowSnapshot], live: [LiveWindow]) -> MatchResult {
        let wanted = snapshots.filter(\.restore)
        let grouper = AppGrouper(refs: wanted.map(\.app) + live.map(\.app))

        var snapshotsByApp: [String: [Int]] = [:]
        for (i, snapshot) in wanted.enumerated() {
            snapshotsByApp[grouper.key(for: snapshot.app), default: []].append(i)
        }
        var liveByApp: [String: [Int]] = [:]
        for (j, window) in live.enumerated() {
            liveByApp[grouper.key(for: window.app), default: []].append(j)
        }

        var matches: [Int: Match] = [:]      // by index in `wanted`
        var ambiguousIndexes = Set<Int>()    // index in `wanted`
        var claimedLive = Set<Int>()         // index in `live`

        // Apps are independent, so the iteration order of the dictionary does not matter.
        for (key, snapshotIndexes) in snapshotsByApp {
            let liveIndexes = liveByApp[key] ?? []
            guard !liveIndexes.isEmpty else { continue }

            // Rows and columns in a fixed order, so that ties always resolve the same way.
            let rows = snapshotIndexes.sorted { (wanted[$0].indexInApp, $0) < (wanted[$1].indexInApp, $1) }
            let cols = liveIndexes.sorted {
                (live[$0].indexInApp, live[$0].windowID) < (live[$1].indexInApp, live[$1].windowID)
            }
            let rules = rows.map { TitleRule(wanted[$0].titleMatch) }
            let scores: [[MatchScore]] = rows.indices.map { r in
                cols.map { score(snapshot: wanted[rows[r]], live: live[$0], rule: rules[r]) }
            }
            let points: [[Int?]] = scores.map { $0.map { $0.isPossible ? $0.total : nil } }

            let assignment = max(rows.count, cols.count) <= exhaustiveLimit
                ? optimalAssignment(points, colCount: cols.count)
                : greedyAssignment(points, colCount: cols.count)

            for (r, assigned) in assignment.enumerated() {
                guard let c = assigned else { continue }
                let snapshotIndex = rows[r]
                matches[snapshotIndex] = Match(snapshotID: wanted[snapshotIndex].id,
                                               windowID: live[cols[c]].windowID, score: scores[r][c])
                claimedLive.insert(cols[c])
                if isAmbiguous(row: r, col: c, points: points, assignment: assignment) {
                    ambiguousIndexes.insert(snapshotIndex)
                }
            }
        }

        return MatchResult(
            matched: wanted.indices.compactMap { matches[$0] },
            missing: wanted.indices.filter { matches[$0] == nil }.map { wanted[$0] },
            extra: live.indices.filter { !claimedLive.contains($0) }.map { live[$0] },
            ambiguous: wanted.indices.filter { ambiguousIndexes.contains($0) }.map { wanted[$0].id }
        )
    }

    // MARK: Ambiguity

    /// A match is ambiguous when the saved window's best and second-best live candidates are within
    /// `ambiguityMargin` points, or when a saved window that got nothing wanted the same live window
    /// about as much (two identical saved windows, one live window).
    private static func isAmbiguous(row: Int, col: Int, points: [[Int?]], assignment: [Int?]) -> Bool {
        let candidates = points[row].compactMap { $0 }.sorted(by: >)
        if candidates.count >= 2, candidates[0] - candidates[1] <= ambiguityMargin { return true }

        guard let own = points[row][col] else { return false }
        for other in points.indices where other != row && assignment[other] == nil {
            if let rival = points[other][col], own - rival <= ambiguityMargin { return true }
        }
        return false
    }

    // MARK: Assignment

    /// The best assignment of rows (saved windows) to columns (live windows) for a matrix of pair scores
    /// (nil = impossible pair). Returns, per row, the column it gets or nil. More matched pairs always beat
    /// a higher total score; among equal totals the first one found wins, and the search tries each row's
    /// best column first, so ties resolve toward the lower row and column.
    static func optimalAssignment(_ points: [[Int?]], colCount: Int) -> [Int?] {
        let rowCount = points.count

        // Upper bound of what rows i... can still add, to cut the search short.
        var bound = [Int](repeating: 0, count: rowCount + 1)
        for i in stride(from: rowCount - 1, through: 0, by: -1) {
            bound[i] = bound[i + 1] + max(points[i].compactMap { $0 }.max() ?? 0, 0)
        }
        // Per row: usable columns, best score first, equal scores by column order.
        let order: [[Int]] = points.map { row in
            row.indices.filter { row[$0] != nil }.sorted { a, b in
                row[a]! != row[b]! ? row[a]! > row[b]! : a < b
            }
        }

        var used = [Bool](repeating: false, count: colCount)
        var current = [Int?](repeating: nil, count: rowCount)
        var best = current
        var bestCount = -1
        var bestTotal = Int.min

        func visit(_ row: Int, _ count: Int, _ total: Int) {
            if row == rowCount {
                if count > bestCount || (count == bestCount && total > bestTotal) {
                    bestCount = count
                    bestTotal = total
                    best = current
                }
                return
            }
            let reachableCount = count + min(rowCount - row, colCount - count)
            if reachableCount < bestCount { return }
            if reachableCount == bestCount, total + bound[row] <= bestTotal { return }

            for col in order[row] where !used[col] {
                used[col] = true
                current[row] = col
                visit(row + 1, count + 1, total + (points[row][col] ?? 0))
                current[row] = nil
                used[col] = false
            }
            visit(row + 1, count, total)
        }
        visit(0, 0, 0)
        return best
    }

    /// Pairs by descending score; equal scores by row and then column. Used above `exhaustiveLimit` windows.
    static func greedyAssignment(_ points: [[Int?]], colCount: Int) -> [Int?] {
        var pairs: [(row: Int, col: Int, score: Int)] = []
        for (r, row) in points.enumerated() {
            for (c, score) in row.enumerated() {
                if let score { pairs.append((r, c, score)) }
            }
        }
        pairs.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.row != b.row { return a.row < b.row }
            return a.col < b.col
        }
        var result = [Int?](repeating: nil, count: points.count)
        var usedCols = Set<Int>()
        for pair in pairs where result[pair.row] == nil && !usedCols.contains(pair.col) {
            result[pair.row] = pair.col
            usedCols.insert(pair.col)
        }
        return result
    }

    // MARK: Helpers

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Removes leading counters "(3)", "[12]", "(99+)" and the markers "●" and "•", in any order.
    private static func stripLeadingMarkers(_ text: Substring) -> Substring {
        var rest = text
        while true {
            rest = rest.drop(while: { $0.isWhitespace })
            guard let first = rest.first else { return rest }
            if first == "\u{25CF}" || first == "\u{2022}" {
                rest = rest.dropFirst()
                continue
            }
            if first == "(" || first == "[" {
                let close: Character = first == "(" ? ")" : "]"
                if let end = rest.firstIndex(of: close), isCounter(rest[rest.index(after: rest.startIndex)..<end]) {
                    rest = rest[rest.index(after: end)...]
                    continue
                }
            }
            return rest
        }
    }

    /// "3", "12", "99+".
    private static func isCounter(_ text: Substring) -> Bool {
        let digits = text.last == "+" ? text.dropLast() : text
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Words of a title: runs of letters and digits.
    private static func tokens(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// Shared words divided by all words (0...1).
    private static func tokenSimilarity(_ a: String, _ b: String) -> Double {
        let x = tokens(a), y = tokens(b)
        let union = x.union(y).count
        guard union > 0 else { return 0 }
        return Double(x.intersection(y).count) / Double(union)
    }

    /// A document path or `file://` URL as a comparable path: decoded, standardized, without a trailing
    /// slash, lower case (the default macOS volumes ignore case). Nil when empty.
    static func normalizeDocumentPath(_ raw: String?) -> String? {
        guard var path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        if path.lowercased().hasPrefix("file:"), let url = URL(string: path), url.isFileURL {
            path = url.path
        }
        path = (path as NSString).standardizingPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? nil : path.lowercased()
    }

    /// 0...frameMax points: full for identical frames, none when the edges are `frameFalloff` points apart on average.
    private static func frameScore(_ a: CGRect, _ b: CGRect) -> Int {
        guard !a.isNull, !b.isNull, !a.isInfinite, !b.isInfinite else { return 0 }
        let distance = (abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.maxX - b.maxX) + abs(a.maxY - b.maxY)) / 4
        guard distance.isFinite else { return 0 }
        let closeness = max(0, 1 - Double(distance) / Weights.frameFalloff)
        return Int((Double(Weights.frameMax) * closeness).rounded())
    }

    // MARK: Title rules

    /// A `TitleMatch` ready to be applied to many titles (a regex is compiled once).
    private struct TitleRule {
        let match: TitleMatch
        let regex: NSRegularExpression?

        init(_ match: TitleMatch) {
            self.match = match
            if case .regex(let pattern) = match {
                regex = try? NSRegularExpression(pattern: pattern)
            } else {
                regex = nil
            }
        }

        func isSatisfied(by title: String?, appName: String?) -> Bool {
            switch match {
            case .any:
                return true
            case .exact(let value):
                guard let title else { return false }
                return WindowMatcher.normalizeTitle(title, appName: appName)
                    == WindowMatcher.normalizeTitle(value, appName: appName)
            case .contains(let value):
                guard let title else { return false }
                let needle = WindowMatcher.collapseWhitespace(value.lowercased())
                if needle.isEmpty { return true }
                if WindowMatcher.collapseWhitespace(title.lowercased()).contains(needle) { return true }
                let normalizedNeedle = WindowMatcher.normalizeTitle(value, appName: appName)
                return !normalizedNeedle.isEmpty
                    && WindowMatcher.normalizeTitle(title, appName: appName).contains(normalizedNeedle)
            case .regex:
                guard let title, let regex else { return false }
                return regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
            }
        }
    }

    // MARK: App grouping

    /// Puts saved and live apps in the same group: by bundle id when both have one, otherwise by name
    /// (ignoring case). An app without a bundle id joins the bundle-id group that has its name, if there
    /// is exactly one; this mirrors `Profile.isSameApp`.
    private struct AppGrouper {
        private var bundleKeysByName: [String: Set<String>] = [:]

        init(refs: [AppRef]) {
            for ref in refs {
                if let id = Self.bundleKey(ref) {
                    bundleKeysByName[Self.nameKey(ref), default: []].insert(id)
                }
            }
        }

        func key(for ref: AppRef) -> String {
            if let id = Self.bundleKey(ref) { return "id:" + id }
            let name = Self.nameKey(ref)
            if let keys = bundleKeysByName[name], keys.count == 1, let only = keys.first { return "id:" + only }
            return "name:" + name
        }

        private static func bundleKey(_ ref: AppRef) -> String? {
            guard let id = ref.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
            return id.lowercased()
        }

        private static func nameKey(_ ref: AppRef) -> String {
            ref.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}

private extension String {
    /// Nil for an empty string.
    var nonEmpty: String? { isEmpty ? nil : self }
}
