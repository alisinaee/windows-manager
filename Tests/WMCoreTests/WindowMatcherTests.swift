import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Tests for the window matcher: which live window is which saved window.
@Suite struct WindowMatcherTests {
    // MARK: Fixtures

    static let chrome = AppRef(bundleID: "com.google.Chrome", name: "Google Chrome")
    static let code = AppRef(bundleID: "com.microsoft.VSCode", name: "Code")
    static let telegram = AppRef(bundleID: "ru.keepcoder.Telegram", name: "Telegram")
    static let terminal = AppRef(bundleID: "com.apple.Terminal", name: "Terminal")
    static let textEdit = AppRef(bundleID: "com.apple.TextEdit", name: "TextEdit")

    static let displayUUID = "5A0E2C1B-0000-4000-8000-0000000000A1"
    static let displayFrame = CGRect(x: 0, y: 0, width: 3840, height: 2160)
    static let defaultFrame = CGRect(x: 100, y: 100, width: 1200, height: 800)

    /// Deterministic snapshot ids: sid(1) ... sid(99).
    static func sid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static func snap(_ n: Int, _ app: AppRef, title: String? = nil, rule: TitleMatch = .any,
                     document: String? = nil, index: Int = 0, frame: CGRect? = nil, fullScreen: Bool = false,
                     restore: Bool = true) -> WindowSnapshot {
        let rect = frame ?? (fullScreen ? displayFrame : defaultFrame)
        return WindowSnapshot(id: sid(n), app: app, title: title, titleMatch: rule, documentPath: document,
                              indexInApp: index, displayUUID: displayUUID, frame: rect,
                              relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
                              placement: .desktop(number: 1), isFullScreen: fullScreen, restore: restore)
    }

    static func live(_ windowID: UInt32, _ app: AppRef, title: String? = nil, document: String? = nil,
                     index: Int = 0, frame: CGRect? = nil, fullScreen: Bool = false) -> LiveWindow {
        let rect = frame ?? (fullScreen ? displayFrame : defaultFrame)
        return LiveWindow(windowID: windowID, pid: 100, app: app, title: title, documentPath: document, frame: rect,
                          displayUUID: displayUUID, spaceIDs: [1], isFullScreen: fullScreen, indexInApp: index)
    }

    /// Snapshot id -> live window id.
    static func pairs(_ result: MatchResult) -> [UUID: UInt32] {
        Dictionary(uniqueKeysWithValues: result.matched.map { ($0.snapshotID, $0.windowID) })
    }

    // MARK: Titles

    @Test func normalizeStripsUnreadCounters() {
        #expect(WindowMatcher.normalizeTitle("(3) Telegram") == "telegram")
        #expect(WindowMatcher.normalizeTitle("[12] Telegram") == "telegram")
        #expect(WindowMatcher.normalizeTitle("(99+) Telegram") == "telegram")
        #expect(WindowMatcher.normalizeTitle("(3) [4] Telegram") == "telegram")
        #expect(WindowMatcher.normalizeTitle("(3)") == "")
        // Not a counter: stays.
        #expect(WindowMatcher.normalizeTitle("(draft) notes") == "(draft) notes")
        #expect(WindowMatcher.normalizeTitle("Inbox (3)") == "inbox (3)")
    }

    @Test func normalizeStripsDirtyMarkers() {
        #expect(WindowMatcher.normalizeTitle("\u{25CF} file.swift \u{2014} project") == "file.swift \u{2014} project")
        #expect(WindowMatcher.normalizeTitle("\u{2022} notes") == "notes")
        #expect(WindowMatcher.normalizeTitle("(2) \u{25CF} file.swift") == "file.swift")
    }

    @Test func normalizeStripsTheTrailingAppName() {
        #expect(WindowMatcher.normalizeTitle("Inbox - Gmail - Google Chrome", appName: "Google Chrome") == "inbox - gmail")
        #expect(WindowMatcher.normalizeTitle("Inbox \u{2014} Google Chrome", appName: "Google Chrome") == "inbox")
        #expect(WindowMatcher.normalizeTitle("Inbox \u{2013} google chrome", appName: "Google Chrome") == "inbox")
        // The app name alone is the title, not a suffix.
        #expect(WindowMatcher.normalizeTitle("Google Chrome", appName: "Google Chrome") == "google chrome")
        // Without an app name nothing is stripped.
        #expect(WindowMatcher.normalizeTitle("Inbox - Google Chrome") == "inbox - google chrome")
        // Only a suffix counts.
        #expect(WindowMatcher.normalizeTitle("Google Chrome - Inbox", appName: "Google Chrome") == "google chrome - inbox")
    }

    @Test func normalizeCollapsesWhitespace() {
        #expect(WindowMatcher.normalizeTitle("  A   b\tc\n d ") == "a b c d")
        #expect(WindowMatcher.normalizeTitle("") == "")
    }

    @Test func anyRuleAlwaysSatisfied() {
        #expect(WindowMatcher.titleSatisfies(.any, nil))
        #expect(WindowMatcher.titleSatisfies(.any, "whatever"))
    }

    @Test func exactRuleComparesNormalizedTitles() {
        #expect(WindowMatcher.titleSatisfies(.exact("Telegram"), "(3) Telegram"))
        #expect(WindowMatcher.titleSatisfies(.exact("(7) telegram"), "Telegram"))
        #expect(WindowMatcher.titleSatisfies(.exact("Inbox"), "Inbox - Google Chrome", appName: "Google Chrome"))
        #expect(!WindowMatcher.titleSatisfies(.exact("Inbox"), "Inbox - Gmail"))
        #expect(!WindowMatcher.titleSatisfies(.exact("Inbox"), nil))
    }

    @Test func containsRuleIgnoresCaseAndAlsoTriesTheRawText() {
        #expect(WindowMatcher.titleSatisfies(.contains("PROJ"), "a.swift \u{2014} proj1"))
        #expect(WindowMatcher.titleSatisfies(.contains("(3)"), "(3) Telegram"))
        #expect(WindowMatcher.titleSatisfies(.contains("telegram"), "(3) Telegram"))
        #expect(!WindowMatcher.titleSatisfies(.contains("slack"), "(3) Telegram"))
        #expect(!WindowMatcher.titleSatisfies(.contains("slack"), nil))
    }

    @Test func regexRuleSearchesTheRawTitle() {
        #expect(WindowMatcher.titleSatisfies(.regex(#"^Project \d+$"#), "Project 42"))
        #expect(!WindowMatcher.titleSatisfies(.regex(#"^Project \d+$"#), "Project X"))
        #expect(WindowMatcher.titleSatisfies(.regex(#"\d+ unread"#), "Mail (12 unread)"))
        #expect(!WindowMatcher.titleSatisfies(.regex("project"), "Project 42"))
        #expect(WindowMatcher.titleSatisfies(.regex("(?i)project"), "Project 42"))
        // A broken pattern and a missing title never match.
        #expect(!WindowMatcher.titleSatisfies(.regex("("), "anything"))
        #expect(!WindowMatcher.titleSatisfies(.regex(".*"), nil))
    }

    // MARK: Matching basics

    @Test func singleWindowPerApp() {
        let snapshots = [
            Self.snap(1, Self.chrome, title: "Inbox - Gmail"),
            Self.snap(2, Self.code, title: "main.swift \u{2014} proj"),
            Self.snap(3, Self.telegram, title: "Telegram"),
        ]
        let windows = [
            Self.live(30, Self.telegram, title: "Telegram"),
            Self.live(10, Self.chrome, title: "Inbox - Gmail"),
            Self.live(20, Self.code, title: "main.swift \u{2014} proj"),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 10, Self.sid(2): 20, Self.sid(3): 30])
        #expect(result.matched.map(\.snapshotID) == [Self.sid(1), Self.sid(2), Self.sid(3)])
        #expect(result.missing.isEmpty)
        #expect(result.extra.isEmpty)
        #expect(result.ambiguous.isEmpty)
        #expect(result.matched[0].reasons.contains(.titleEqual))
    }

    @Test func singleWindowMatchesEvenWhenNothingLooksAlike() {
        // Same app, one window each: it is the window, whatever the title and place.
        let result = WindowMatcher.match(
            snapshots: [Self.snap(1, Self.chrome, title: "Old page")],
            live: [Self.live(10, Self.chrome, title: "Totally different", frame: CGRect(x: 2000, y: 900, width: 300, height: 300))])
        #expect(Self.pairs(result) == [Self.sid(1): 10])
        #expect(result.missing.isEmpty)
    }

    @Test func twoChromeWindowsWhoseOrderChanged() {
        let left = CGRect(x: 0, y: 40, width: 1200, height: 800)
        let right = CGRect(x: 1300, y: 40, width: 1200, height: 800)
        let snapshots = [
            Self.snap(1, Self.chrome, title: "Inbox - Gmail - Google Chrome", index: 0, frame: left),
            Self.snap(2, Self.chrome, title: "GitHub - Google Chrome", index: 1, frame: right),
        ]
        // The windows were re-ordered and even moved to each other's place: the titles decide.
        let windows = [
            Self.live(11, Self.chrome, title: "GitHub - Google Chrome", index: 0, frame: left),
            Self.live(12, Self.chrome, title: "Inbox - Gmail - Google Chrome", index: 1, frame: right),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 12, Self.sid(2): 11])
        #expect(result.missing.isEmpty)
        #expect(result.extra.isEmpty)
        #expect(result.ambiguous.isEmpty)
    }

    @Test func twoChromeWindowsAreMatchedWhateverTheInputOrder() {
        let snapshots = [
            Self.snap(1, Self.chrome, title: "Inbox - Gmail", index: 0),
            Self.snap(2, Self.chrome, title: "GitHub", index: 1),
        ]
        let windows = [
            Self.live(11, Self.chrome, title: "GitHub", index: 0),
            Self.live(12, Self.chrome, title: "Inbox - Gmail", index: 1),
        ]
        let expected = Self.pairs(WindowMatcher.match(snapshots: snapshots, live: windows))
        #expect(expected == [Self.sid(1): 12, Self.sid(2): 11])
        #expect(Self.pairs(WindowMatcher.match(snapshots: snapshots.reversed(), live: windows)) == expected)
        #expect(Self.pairs(WindowMatcher.match(snapshots: snapshots, live: windows.reversed())) == expected)
        #expect(Self.pairs(WindowMatcher.match(snapshots: snapshots.reversed(), live: windows.reversed())) == expected)
    }

    @Test func twoVSCodeFullScreenWindowsAreNotSwapped() {
        let snapshots = [
            Self.snap(1, Self.code, title: "a.swift \u{2014} proj1", index: 0, fullScreen: true),
            Self.snap(2, Self.code, title: "b.swift \u{2014} proj2", index: 1, fullScreen: true),
        ]
        // Same frame (the whole display), the other one is in front now, and b.swift has unsaved changes.
        let windows = [
            Self.live(21, Self.code, title: "\u{25CF} b.swift \u{2014} proj2", index: 0, fullScreen: true),
            Self.live(22, Self.code, title: "a.swift \u{2014} proj1", index: 1, fullScreen: true),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 22, Self.sid(2): 21])
        #expect(result.ambiguous.isEmpty)
    }

    @Test func titleWordsMatchWhenTheAppAddsASuffix() {
        // VS Code's window title ends with "Visual Studio Code", but the app is called "Code".
        let snapshots = [
            Self.snap(1, Self.code, title: "a.swift \u{2014} proj1", index: 0, fullScreen: true),
            Self.snap(2, Self.code, title: "b.swift \u{2014} proj2", index: 1, fullScreen: true),
        ]
        let windows = [
            Self.live(21, Self.code, title: "b.swift \u{2014} proj2 \u{2014} Visual Studio Code", index: 0, fullScreen: true),
            Self.live(22, Self.code, title: "a.swift \u{2014} proj1 \u{2014} Visual Studio Code", index: 1, fullScreen: true),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 22, Self.sid(2): 21])
        #expect(result.matched.allSatisfy { $0.reasons.contains(.titleSimilar) })
    }

    @Test func telegramUnreadCounterDoesNotBreakTheMatch() {
        let snapshots = [
            Self.snap(1, Self.telegram, title: "Telegram", index: 0),
            Self.snap(2, Self.telegram, title: "Saved Messages", index: 1),
        ]
        let windows = [
            Self.live(31, Self.telegram, title: "Saved Messages", index: 0),
            Self.live(32, Self.telegram, title: "(3) Telegram", index: 1),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 32, Self.sid(2): 31])
        #expect(result.matched.first { $0.snapshotID == Self.sid(1) }?.reasons.contains(.titleEqual) == true)
    }

    @Test func titlesThatAreUnknownFallBackToFrameAndOrder() {
        // No Screen Recording / Accessibility: no titles at all. The frames tell the windows apart.
        let a = CGRect(x: 0, y: 40, width: 900, height: 700)
        let b = CGRect(x: 1900, y: 40, width: 900, height: 700)
        let snapshots = [
            Self.snap(1, Self.terminal, index: 0, frame: a),
            Self.snap(2, Self.terminal, index: 1, frame: b),
        ]
        let windows = [
            Self.live(41, Self.terminal, index: 0, frame: b),
            Self.live(42, Self.terminal, index: 1, frame: a),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 42, Self.sid(2): 41])
    }

    // MARK: Missing and extra

    @Test func closedAppIsMissing() {
        let snapshots = [
            Self.snap(1, Self.chrome, title: "Inbox"),
            Self.snap(2, Self.telegram, title: "Telegram"),
        ]
        let windows = [Self.live(10, Self.chrome, title: "Inbox")]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 10])
        #expect(result.missing.map(\.id) == [Self.sid(2)])
        #expect(result.extra.isEmpty)
    }

    @Test func fewerWindowsThanSavedLeavesTheWeakerOneMissing() {
        let snapshots = [
            Self.snap(1, Self.chrome, title: "Inbox - Gmail", index: 0),
            Self.snap(2, Self.chrome, title: "GitHub", index: 1),
        ]
        let windows = [Self.live(10, Self.chrome, title: "GitHub", index: 0)]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(2): 10])
        #expect(result.missing.map(\.id) == [Self.sid(1)])
        #expect(result.extra.isEmpty)
    }

    @Test func extraLiveWindowsAreReported() {
        let snapshots = [Self.snap(1, Self.chrome, title: "Inbox")]
        let windows = [
            Self.live(10, Self.chrome, title: "Inbox", index: 0),
            Self.live(11, Self.chrome, title: "Some other page", index: 1),
            Self.live(50, Self.textEdit, title: "Untitled"),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 10])
        #expect(result.extra.map(\.windowID) == [11, 50])
        #expect(result.missing.isEmpty)
    }

    @Test func snapshotsThatAreNotRestoredAreIgnored() {
        let snapshots = [
            Self.snap(1, Self.chrome, title: "Inbox", index: 0),
            Self.snap(2, Self.chrome, title: "GitHub", index: 1, restore: false),
        ]
        let windows = [
            Self.live(10, Self.chrome, title: "Inbox", index: 0),
            Self.live(11, Self.chrome, title: "GitHub", index: 1),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 10])
        #expect(result.missing.isEmpty)
        #expect(result.extra.map(\.windowID) == [11])
        #expect(result.ambiguous.isEmpty)
    }

    @Test func emptyInputs() {
        #expect(WindowMatcher.match(snapshots: [], live: []) == MatchResult())
        let onlySnapshots = WindowMatcher.match(snapshots: [Self.snap(1, Self.chrome)], live: [])
        #expect(onlySnapshots.missing.map(\.id) == [Self.sid(1)])
        let onlyLive = WindowMatcher.match(snapshots: [], live: [Self.live(1, Self.chrome)])
        #expect(onlyLive.extra.map(\.windowID) == [1])
    }

    // MARK: App grouping

    @Test func appsAreGroupedByBundleIDThenNameIgnoringCase() {
        let upper = AppRef(bundleID: "COM.GOOGLE.CHROME", name: "Chrome")
        let noBundle = AppRef(bundleID: nil, name: "google chrome")
        let other = AppRef(bundleID: "com.google.Chrome.canary", name: "Google Chrome")

        // Bundle ids compare ignoring case.
        let a = WindowMatcher.match(snapshots: [Self.snap(1, Self.chrome, title: "x")], live: [Self.live(10, upper, title: "x")])
        #expect(Self.pairs(a) == [Self.sid(1): 10])

        // A saved app without a bundle id is found by name.
        let b = WindowMatcher.match(snapshots: [Self.snap(1, noBundle, title: "x")], live: [Self.live(10, Self.chrome, title: "x")])
        #expect(Self.pairs(b) == [Self.sid(1): 10])

        // Two different bundle ids are two different apps, even with the same name.
        let c = WindowMatcher.match(snapshots: [Self.snap(1, Self.chrome, title: "x")], live: [Self.live(10, other, title: "x")])
        #expect(c.matched.isEmpty)
        #expect(c.missing.map(\.id) == [Self.sid(1)])
        #expect(c.extra.map(\.windowID) == [10])
    }

    // MARK: User rules

    @Test func ruleExcludesTheOtherwiseBestWindow() {
        // The saved title says "Inbox" but the user pinned this slot to the window titled "Docs".
        let snapshots = [Self.snap(1, Self.chrome, title: "Inbox", rule: .exact("Docs"), index: 0)]
        let windows = [
            Self.live(10, Self.chrome, title: "Inbox", index: 0),
            Self.live(11, Self.chrome, title: "Docs", index: 1),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 11])
        #expect(result.extra.map(\.windowID) == [10])
        #expect(result.matched[0].reasons.contains(.userRule))

        // Without the rule the title wins.
        let free = WindowMatcher.match(snapshots: [Self.snap(1, Self.chrome, title: "Inbox", index: 0)], live: windows)
        #expect(Self.pairs(free) == [Self.sid(1): 10])
    }

    @Test func noWindowPassingTheRuleMeansMissing() {
        let snapshots = [Self.snap(1, Self.chrome, title: "Inbox", rule: .contains("calendar"))]
        let windows = [Self.live(10, Self.chrome, title: "Inbox")]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(result.matched.isEmpty)
        #expect(result.missing.map(\.id) == [Self.sid(1)])
        #expect(result.extra.map(\.windowID) == [10])
    }

    @Test func containsRuleSelectsTheWindow() {
        let snapshots = [
            Self.snap(1, Self.code, title: "whatever", rule: .contains("proj2"), index: 0),
            Self.snap(2, Self.code, title: "whatever", rule: .contains("proj1"), index: 1),
        ]
        let windows = [
            Self.live(21, Self.code, title: "a.swift \u{2014} proj1", index: 0),
            Self.live(22, Self.code, title: "b.swift \u{2014} proj2", index: 1),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 22, Self.sid(2): 21])
    }

    @Test func regexRuleSelectsTheWindow() {
        let snapshots = [
            Self.snap(1, Self.terminal, rule: .regex(#"^build \d+$"#), index: 0),
            Self.snap(2, Self.terminal, rule: .regex(#"^logs"#), index: 1),
        ]
        let windows = [
            Self.live(41, Self.terminal, title: "logs tail", index: 0),
            Self.live(42, Self.terminal, title: "build 17", index: 1),
            Self.live(43, Self.terminal, title: "zsh", index: 2),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 42, Self.sid(2): 41])
        #expect(result.extra.map(\.windowID) == [43])
    }

    @Test func exactRuleIgnoresCountersAndAppSuffix() {
        let snapshots = [Self.snap(1, Self.telegram, rule: .exact("Telegram"), index: 0)]
        let windows = [
            Self.live(31, Self.telegram, title: "Settings", index: 0),
            Self.live(32, Self.telegram, title: "(5) Telegram", index: 1),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 32])
    }

    @Test func aRuleBoundWindowTakesItsOnlyCandidateEvenIfAnotherWindowFitsBetter() {
        // Slot 2 can only be the "alpha" window; slot 1 fits it better by title but has the other window as a fallback.
        let snapshots = [
            Self.snap(1, Self.textEdit, title: "alpha", index: 0),
            Self.snap(2, Self.textEdit, title: "beta", rule: .contains("alpha"), index: 1),
        ]
        let windows = [
            Self.live(51, Self.textEdit, title: "alpha", index: 0),
            Self.live(52, Self.textEdit, title: "beta", index: 1),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 52, Self.sid(2): 51])
        #expect(result.missing.isEmpty)
    }

    // MARK: Documents

    @Test func documentPathWinsOverTitle() {
        let snapshots = [
            Self.snap(1, Self.textEdit, title: "Draft.txt", document: "/Users/ali/Notes/draft.txt", index: 0),
            Self.snap(2, Self.textEdit, title: "Todo.txt", document: "/Users/ali/Notes/todo.txt", index: 1),
        ]
        // The file was renamed in the title bar of the other window: titles point the wrong way, paths are right.
        let windows = [
            Self.live(51, Self.textEdit, title: "Draft.txt", document: "file:///Users/ali/Notes/todo.txt", index: 0),
            Self.live(52, Self.textEdit, title: "Todo.txt", document: "file:///Users/ali/Notes/draft.txt", index: 1),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 52, Self.sid(2): 51])
        #expect(result.matched.allSatisfy { $0.reasons.contains(.documentPath) })
    }

    @Test func documentPathsCompareAsPaths() {
        let norm = WindowMatcher.normalizeDocumentPath
        #expect(norm("file:///Users/ali/My%20Notes/a.txt") == norm("/Users/ali/My Notes/a.txt"))
        #expect(norm("/Users/ali/Notes/") == norm("/users/ali/notes"))
        #expect(norm("/Users/ali/./Notes/../Notes/a.txt") == norm("/Users/ali/Notes/a.txt"))
        #expect(norm("   ") == nil)
        #expect(norm(nil) == nil)
    }

    @Test func differentDocumentsCountAgainstThePair() {
        let saved = Self.snap(1, Self.textEdit, title: "same", document: "/a.txt")
        let sameDoc = Self.live(51, Self.textEdit, title: "same", document: "/a.txt")
        let otherDoc = Self.live(52, Self.textEdit, title: "same", document: "/b.txt")
        let noDoc = Self.live(53, Self.textEdit, title: "same")
        let s1 = WindowMatcher.score(snapshot: saved, live: sameDoc)
        let s2 = WindowMatcher.score(snapshot: saved, live: otherDoc)
        let s3 = WindowMatcher.score(snapshot: saved, live: noDoc)
        #expect(s1.total > s3.total)
        #expect(s3.total > s2.total)
        #expect(s2.reasons.contains(.documentPathDiffers))
        #expect(!s3.reasons.contains(.documentPath) && !s3.reasons.contains(.documentPathDiffers))
    }

    // MARK: Scores

    @Test func scoreOrdersTheEvidence() {
        let saved = Self.snap(1, Self.chrome, title: "Inbox - Gmail", index: 0)
        let equalTitle = WindowMatcher.score(snapshot: saved, live: Self.live(1, Self.chrome, title: "(2) Inbox - Gmail"))
        let similar = WindowMatcher.score(snapshot: saved, live: Self.live(2, Self.chrome, title: "Inbox - Gmail - work account"))
        let unrelated = WindowMatcher.score(snapshot: saved, live: Self.live(3, Self.chrome, title: "GitHub"))
        #expect(equalTitle.reasons.contains(.titleEqual))
        #expect(similar.reasons.contains(.titleSimilar))
        #expect(!unrelated.reasons.contains(.titleEqual) && !unrelated.reasons.contains(.titleSimilar))
        #expect(equalTitle.total > similar.total)
        #expect(similar.total > unrelated.total)
    }

    @Test func scoreRewardsSameStateDisplayFrameAndIndex() {
        let saved = Self.snap(1, Self.chrome, title: "x", index: 2)
        let perfect = WindowMatcher.score(snapshot: saved, live: Self.live(1, Self.chrome, title: "x", index: 2))
        #expect(perfect.reasons.contains(.fullScreen))
        #expect(perfect.reasons.contains(.display))
        #expect(perfect.reasons.contains(.frame))
        #expect(perfect.reasons.contains(.indexInApp))

        var elsewhere = Self.live(2, Self.chrome, title: "x", index: 0, frame: CGRect(x: 3000, y: 1400, width: 400, height: 300),
                                  fullScreen: true)
        elsewhere.displayUUID = "another-display"
        let far = WindowMatcher.score(snapshot: saved, live: elsewhere)
        #expect(!far.reasons.contains(.fullScreen))
        #expect(!far.reasons.contains(.display))
        #expect(!far.reasons.contains(.frame))
        #expect(!far.reasons.contains(.indexInApp))
        #expect(perfect.total > far.total)
    }

    @Test func closerFramesScoreHigher() {
        let saved = Self.snap(1, Self.terminal, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        let near = WindowMatcher.score(snapshot: saved, live: Self.live(1, Self.terminal, frame: CGRect(x: 120, y: 110, width: 800, height: 600)))
        let farther = WindowMatcher.score(snapshot: saved, live: Self.live(2, Self.terminal, frame: CGRect(x: 600, y: 300, width: 800, height: 600)))
        #expect(near.total > farther.total)
    }

    @Test func aFailedRuleMakesTheScoreImpossible() {
        let saved = Self.snap(1, Self.chrome, title: "x", rule: .exact("y"))
        let score = WindowMatcher.score(snapshot: saved, live: Self.live(1, Self.chrome, title: "x"))
        #expect(!score.isPossible)
        #expect(score.reasons == [.ruleFailed])
        #expect(WindowMatcher.score(snapshot: saved, live: Self.live(2, Self.chrome, title: "y")).isPossible)
    }

    // MARK: Ambiguity

    @Test func identicalLookingWindowsAreAmbiguous() {
        let snapshots = [
            Self.snap(1, Self.terminal, title: "zsh", index: 0, frame: CGRect(x: 100, y: 100, width: 800, height: 600)),
            Self.snap(2, Self.terminal, title: "zsh", index: 1, frame: CGRect(x: 120, y: 120, width: 800, height: 600)),
        ]
        let windows = [
            Self.live(41, Self.terminal, title: "zsh", index: 0, frame: CGRect(x: 110, y: 110, width: 800, height: 600)),
            Self.live(42, Self.terminal, title: "zsh", index: 1, frame: CGRect(x: 115, y: 115, width: 800, height: 600)),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(result.matched.count == 2)
        #expect(result.ambiguous == [Self.sid(1), Self.sid(2)])
    }

    @Test func distinctTitlesAreNotAmbiguous() {
        let snapshots = [
            Self.snap(1, Self.terminal, title: "build", index: 0, frame: CGRect(x: 100, y: 100, width: 800, height: 600)),
            Self.snap(2, Self.terminal, title: "logs", index: 1, frame: CGRect(x: 120, y: 120, width: 800, height: 600)),
        ]
        let windows = [
            Self.live(41, Self.terminal, title: "build", index: 0, frame: CGRect(x: 110, y: 110, width: 800, height: 600)),
            Self.live(42, Self.terminal, title: "logs", index: 1, frame: CGRect(x: 115, y: 115, width: 800, height: 600)),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(result.ambiguous.isEmpty)
    }

    @Test func twoIdenticalSavedWindowsForOneLiveWindowAreAmbiguous() {
        // Which of the two saved "zsh" windows is this one? The match is a guess; the other one is missing.
        let snapshots = [
            Self.snap(1, Self.terminal, title: "zsh", index: 0),
            Self.snap(2, Self.terminal, title: "zsh", index: 1),
        ]
        let result = WindowMatcher.match(snapshots: snapshots, live: [Self.live(41, Self.terminal, title: "zsh", index: 0)])
        #expect(Self.pairs(result) == [Self.sid(1): 41])
        #expect(result.missing.map(\.id) == [Self.sid(2)])
        #expect(result.ambiguous == [Self.sid(1)])
    }

    // MARK: Assignment

    @Test func exhaustiveSearchBeatsGreedyWhereGreedyStrandsAWindow() {
        let points: [[Int?]] = [[10, 9], [9, nil]]
        #expect(WindowMatcher.greedyAssignment(points, colCount: 2) == [0, nil])
        #expect(WindowMatcher.optimalAssignment(points, colCount: 2) == [1, 0])
    }

    @Test func optimalAssignmentMaximizesTheTotal() {
        // Greedy would take 9 + 5 = 14, the best is 8 + 8 = 16.
        let points: [[Int?]] = [[9, 8], [8, 5]]
        #expect(WindowMatcher.greedyAssignment(points, colCount: 2) == [0, 1])
        #expect(WindowMatcher.optimalAssignment(points, colCount: 2) == [1, 0])
    }

    @Test func optimalAssignmentResolvesTiesTowardLowerIndexes() {
        let points: [[Int?]] = [[5, 5, 5], [5, 5, 5], [5, 5, 5]]
        #expect(WindowMatcher.optimalAssignment(points, colCount: 3) == [0, 1, 2])
        #expect(WindowMatcher.greedyAssignment(points, colCount: 3) == [0, 1, 2])
    }

    @Test func eightWindowsOfOneAppAreSolvedExactly() {
        // 8 is the exhaustive limit. Rotate the windows so no window sits at its own index.
        let snapshots = (0..<8).map { i in
            Self.snap(i + 1, Self.terminal, title: "tab \(i)", index: i,
                      frame: CGRect(x: i * 300, y: 0, width: 500, height: 400))
        }
        let windows = (0..<8).map { i in
            Self.live(UInt32(100 + i), Self.terminal, title: "tab \((i + 3) % 8)", index: i,
                      frame: CGRect(x: i * 300, y: 0, width: 500, height: 400))
        }
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(result.matched.count == 8)
        for i in 0..<8 {
            // Snapshot i has title "tab i", which window (j + 3) % 8 == i carries.
            let j = (i + 5) % 8
            #expect(Self.pairs(result)[Self.sid(i + 1)] == UInt32(100 + j))
        }
    }

    @Test func moreThanEightWindowsUseTheGreedyPathAndStayDeterministic() {
        let count = 10
        let snapshots = (0..<count).map { i in
            Self.snap(i + 1, Self.terminal, title: "zsh", index: i,
                      frame: CGRect(x: i * 100, y: 0, width: 500, height: 400))
        }
        let windows = (0..<count).map { i in
            Self.live(UInt32(100 + i), Self.terminal, title: "zsh", index: i,
                      frame: CGRect(x: i * 100, y: 0, width: 500, height: 400))
        }
        let expected = Dictionary(uniqueKeysWithValues: (0..<count).map { (Self.sid($0 + 1), UInt32(100 + $0)) })

        let first = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(first) == expected)
        #expect(first.missing.isEmpty && first.extra.isEmpty)

        // Same input, same answer; shuffled or reversed live input, same answer.
        #expect(WindowMatcher.match(snapshots: snapshots, live: windows) == first)
        #expect(Self.pairs(WindowMatcher.match(snapshots: snapshots, live: windows.reversed())) == expected)
        let shuffled = [5, 0, 9, 3, 7, 1, 8, 2, 6, 4].map { windows[$0] }
        #expect(Self.pairs(WindowMatcher.match(snapshots: snapshots, live: shuffled)) == expected)
    }

    @Test func completelyIdenticalWindowsAreMatchedInAStableOrder() {
        // 10 windows that cannot be told apart at all: ties go by saved order and by window id,
        // whatever order the live windows arrive in.
        let snapshots = (0..<10).map { Self.snap($0 + 1, Self.terminal, title: "zsh") }
        let windows = (0..<10).map { Self.live(UInt32(200 + $0), Self.terminal, title: "zsh") }
        let expected = Dictionary(uniqueKeysWithValues: (0..<10).map { (Self.sid($0 + 1), UInt32(200 + $0)) })
        #expect(Self.pairs(WindowMatcher.match(snapshots: snapshots, live: windows)) == expected)
        #expect(Self.pairs(WindowMatcher.match(snapshots: snapshots, live: windows.reversed())) == expected)
    }

    @Test func moreLiveWindowsThanEightKeepsTheBestOnes() {
        // Two saved windows, twelve live ones: the greedy path still finds the right two.
        let snapshots = [
            Self.snap(1, Self.chrome, title: "Inbox - Gmail", index: 0),
            Self.snap(2, Self.chrome, title: "GitHub", index: 1),
        ]
        var windows = (0..<12).map { Self.live(UInt32(10 + $0), Self.chrome, title: "Tab \($0)", index: $0) }
        windows[7].title = "GitHub"
        windows[9].title = "Inbox - Gmail"
        let result = WindowMatcher.match(snapshots: snapshots, live: windows)
        #expect(Self.pairs(result) == [Self.sid(1): 19, Self.sid(2): 17])
        #expect(result.extra.count == 10)
    }
}
