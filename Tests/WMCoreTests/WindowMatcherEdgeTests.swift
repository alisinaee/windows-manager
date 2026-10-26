import CoreGraphics
import Foundation
import Testing
@testable import WMCore

// Fixtures for the edge cases below.
private let chrome = AppRef(bundleID: "com.google.Chrome", name: "Google Chrome")
private let telegram = AppRef(bundleID: "ru.keepcoder.Telegram", name: "Telegram")
private let preview = AppRef(bundleID: "com.apple.Preview", name: "Preview")

private let displayUUID = "EDGE0000-0000-4000-8000-0000000000A1"
private let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

private func sid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-A000-%012d", n))!
}

private func snap(_ n: Int, _ app: AppRef, title: String? = nil, rule: TitleMatch = .any,
                 document: String? = nil, index: Int = 0, frame rect: CGRect = frame,
                 restore: Bool = true) -> WindowSnapshot {
    WindowSnapshot(id: sid(n), app: app, title: title, titleMatch: rule, documentPath: document,
                   indexInApp: index, displayUUID: displayUUID, frame: rect,
                   relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 1), placement: .desktop(number: 1),
                   restore: restore)
}

private func live(_ windowID: UInt32, _ app: AppRef, title: String? = nil, document: String? = nil,
                 index: Int = 0, frame rect: CGRect = frame) -> LiveWindow {
    LiveWindow(windowID: windowID, pid: 77, app: app, title: title, documentPath: document, frame: rect,
               displayUUID: displayUUID, spaceIDs: [1], indexInApp: index)
}

private func pairs(_ result: MatchResult) -> [UUID: UInt32] {
    Dictionary(uniqueKeysWithValues: result.matched.map { ($0.snapshotID, $0.windowID) })
}


/// Edge cases of the window matcher: empty inputs, duplicate titles, documents and frames that cannot be
/// compared, title rules that cannot run, and the assignment helpers at their limits.
@Suite struct WindowMatcherEdgeTests {
    // MARK: Empty inputs

    @Test func noSavedWindowsLeavesEveryLiveWindowExtra() {
        let result = WindowMatcher.match(snapshots: [], live: [live(1, chrome), live(2, telegram)])
        #expect(result.matched.isEmpty)
        #expect(result.missing.isEmpty)
        #expect(result.ambiguous.isEmpty)
        #expect(result.extra.map(\.windowID) == [1, 2])
    }

    @Test func noLiveWindowsLeavesEverySavedWindowMissing() {
        let saved = [snap(1, chrome, title: "Inbox"), snap(2, telegram)]
        let result = WindowMatcher.match(snapshots: saved, live: [])
        #expect(result.matched.isEmpty)
        #expect(result.extra.isEmpty)
        #expect(result.missing.map(\.id) == [sid(1), sid(2)])
    }

    @Test func savedWindowsThatAreNotRestoredNeverTakeLiveWindows() {
        let saved = [snap(1, chrome, title: "Inbox", restore: false), snap(2, chrome, title: "Docs")]
        let lives = [live(10, chrome, title: "Inbox"), live(11, chrome, title: "Docs")]
        let result = WindowMatcher.match(snapshots: saved, live: lives)
        #expect(pairs(result) == [sid(2): 11])
        #expect(result.extra.map(\.windowID) == [10])
        #expect(result.missing.isEmpty)
    }

    // MARK: Duplicate titles

    @Test func twoWindowsWithTheSameTitleAreToldApartByFrame() {
        let left = CGRect(x: 100, y: 100, width: 800, height: 600)
        let right = CGRect(x: 2000, y: 100, width: 800, height: 600)
        let saved = [snap(1, chrome, title: "Inbox", index: 0, frame: left),
                     snap(2, chrome, title: "Inbox", index: 1, frame: right)]
        // The window server lists the right-hand window first.
        let lives = [live(201, chrome, title: "Inbox", index: 0, frame: right),
                     live(202, chrome, title: "Inbox", index: 1, frame: left)]
        let result = WindowMatcher.match(snapshots: saved, live: lives)
        #expect(pairs(result) == [sid(1): 202, sid(2): 201])
        #expect(result.ambiguous.isEmpty)
    }

    @Test func twoWindowsWithTheSameTitleAreToldApartByDocument() {
        let saved = [snap(1, preview, title: "Untitled", document: "/Users/ali/one.pdf"),
                     snap(2, preview, title: "Untitled", document: "/Users/ali/two.pdf", index: 1)]
        let lives = [live(301, preview, title: "Untitled", document: "/Users/ali/two.pdf"),
                     live(302, preview, title: "Untitled", document: "/Users/ali/one.pdf", index: 1)]
        let result = WindowMatcher.match(snapshots: saved, live: lives)
        #expect(pairs(result) == [sid(1): 302, sid(2): 301])
    }

    @Test func sameTitleInAnotherAppNeverMatches() {
        let result = WindowMatcher.match(snapshots: [snap(1, chrome, title: "Inbox")],
                                         live: [live(5, telegram, title: "Inbox")])
        #expect(result.matched.isEmpty)
        #expect(result.missing.map(\.id) == [sid(1)])
        #expect(result.extra.map(\.windowID) == [5])
    }

    @Test func oneAppsWindowsDoNotLeakIntoAnotherAppsMatch() {
        let saved = [snap(1, chrome, title: "Inbox"), snap(2, chrome, title: "Docs", index: 1),
                     snap(3, telegram, title: "Telegram")]
        let lives = [live(11, telegram, title: "Telegram"), live(12, chrome, title: "Docs", index: 1),
                     live(13, chrome, title: "Inbox")]
        let result = WindowMatcher.match(snapshots: saved, live: lives)
        #expect(pairs(result) == [sid(1): 13, sid(2): 12, sid(3): 11])
        #expect(result.missing.isEmpty)
        #expect(result.extra.isEmpty)
    }

    // MARK: Titles that cannot be compared

    @Test func emptyTitlesNeverCountAsEqual() {
        let score = WindowMatcher.score(snapshot: snap(1, chrome, title: ""),
                                        live: live(1, chrome, title: "   "))
        #expect(!score.reasons.contains(.titleEqual))
        #expect(!score.reasons.contains(.titleSimilar))
    }

    @Test func missingLiveTitleGivesNoTitlePoints() {
        let score = WindowMatcher.score(snapshot: snap(1, chrome, title: "Inbox"),
                                        live: live(1, chrome, title: nil))
        #expect(!score.reasons.contains(.titleEqual))
        #expect(!score.reasons.contains(.titleSimilar))
        #expect(score.isPossible)
    }

    @Test func titlesSharingTooLittleAddNothing() {
        let score = WindowMatcher.score(snapshot: snap(1, chrome, title: "Alpha Beta"),
                                        live: live(1, chrome, title: "Gamma Delta"))
        #expect(!score.reasons.contains(.titleSimilar))
        #expect(!score.reasons.contains(.titleEqual))
    }

    @Test func titlesSharingMostWordsCountAsSimilar() {
        let score = WindowMatcher.score(snapshot: snap(1, chrome, title: "Report Q3 draft"),
                                        live: live(1, chrome, title: "Report Q3 final"))
        #expect(score.reasons.contains(.titleSimilar))
        #expect(!score.reasons.contains(.titleEqual))
    }

    @Test func counterLikeTextThatIsNotACounterIsKept() {
        #expect(WindowMatcher.normalizeTitle("(draft) Notes") == "(draft) notes")
        #expect(WindowMatcher.normalizeTitle("(3 new) Mail") == "(3 new) mail")
        #expect(WindowMatcher.normalizeTitle("(3) Mail") == "mail")
    }

    @Test func nothingIsStrippedFromAnEmptyTitle() {
        #expect(WindowMatcher.normalizeTitle("") == "")
        #expect(WindowMatcher.normalizeTitle("   ", appName: "Notes") == "")
    }

    // MARK: Documents

    @Test func documentPathOnlyCountsWhenBothSidesHaveOne() {
        let withoutLive = WindowMatcher.score(snapshot: snap(1, preview, document: "/a.pdf"),
                                              live: live(1, preview, document: nil))
        #expect(!withoutLive.reasons.contains(.documentPath))
        #expect(!withoutLive.reasons.contains(.documentPathDiffers))

        let emptySaved = WindowMatcher.score(snapshot: snap(1, preview, document: ""),
                                             live: live(1, preview, document: "/a.pdf"))
        #expect(!emptySaved.reasons.contains(.documentPathDiffers))
        #expect(WindowMatcher.normalizeDocumentPath("   ") == nil)
    }

    // MARK: Frames

    @Test func nullAndNotANumberFramesGiveNoFramePoints() {
        let nullFrame = WindowMatcher.score(snapshot: snap(1, chrome, frame: .null),
                                            live: live(1, chrome))
        #expect(!nullFrame.reasons.contains(.frame))
        #expect(nullFrame.total >= 0)

        let nanFrame = CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)
        let nanScore = WindowMatcher.score(snapshot: snap(2, chrome, frame: nanFrame),
                                           live: live(2, chrome))
        #expect(!nanScore.reasons.contains(.frame))
        #expect(nanScore.isPossible)
    }

    @Test func identicalFrameGivesTheFrameReasonAndDistantOnesDoNot() {
        let same = WindowMatcher.score(snapshot: snap(1, chrome), live: live(1, chrome))
        #expect(same.reasons.contains(.frame))

        let far = CGRect(x: 6000, y: 100, width: 800, height: 600)
        let distant = WindowMatcher.score(snapshot: snap(1, chrome), live: live(1, chrome, frame: far))
        #expect(!distant.reasons.contains(.frame))
        #expect(distant.total < same.total)
    }

    // MARK: Title rules that cannot run

    @Test func emptyContainsRuleOnlyNeedsATitle() {
        #expect(WindowMatcher.titleSatisfies(.contains("   "), "Anything"))
        #expect(!WindowMatcher.titleSatisfies(.contains(""), nil))
    }

    @Test func exactAndRegexRulesFailWithoutATitle() {
        #expect(!WindowMatcher.titleSatisfies(.exact("Inbox"), nil))
        #expect(!WindowMatcher.titleSatisfies(.regex(".*"), nil))
        #expect(WindowMatcher.titleSatisfies(.any, nil))
    }

    @Test func invalidRegexNeverMatchesAndTheWindowStaysMissing() {
        #expect(!WindowMatcher.titleSatisfies(.regex("("), "("))
        let result = WindowMatcher.match(snapshots: [snap(1, chrome, title: "Inbox", rule: .regex("("))],
                                         live: [live(9, chrome, title: "Inbox")])
        #expect(result.matched.isEmpty)
        #expect(result.missing.map(\.id) == [sid(1)])
        #expect(result.extra.map(\.windowID) == [9])
    }

    @Test func regexIsCaseSensitiveUnlessTheFlagIsSet() {
        #expect(!WindowMatcher.titleSatisfies(.regex("inbox"), "Inbox"))
        #expect(WindowMatcher.titleSatisfies(.regex("(?i)inbox"), "Inbox"))
    }

    // MARK: Scores

    @Test func impossibleScoreHasNoPointsAndIsNeverPossible() {
        let impossible = MatchScore.impossible
        #expect(!impossible.isPossible)
        #expect(impossible.total == 0)
        #expect(impossible.reasons == [.ruleFailed])
    }

    @Test func documentAndDisplayAndStateAloneGiveTheirReasons() {
        let score = WindowMatcher.score(
            snapshot: snap(1, preview, document: "/a.pdf"),
            live: live(1, preview, document: "/A.pdf/"))
        #expect(score.reasons.contains(.documentPath))
        #expect(score.reasons.contains(.display))
        #expect(score.reasons.contains(.fullScreen))
    }

    // MARK: Assignment helpers at their limits

    @Test func assignmentWithNoRowsOrNoColumnsIsEmpty() {
        #expect(WindowMatcher.optimalAssignment([], colCount: 3).isEmpty)
        #expect(WindowMatcher.optimalAssignment([[nil]], colCount: 0) == [nil])
        #expect(WindowMatcher.greedyAssignment([], colCount: 0).isEmpty)
        #expect(WindowMatcher.greedyAssignment([[nil]], colCount: 0) == [nil])
    }

    @Test func assignmentSkipsImpossiblePairsAndUsesTheOnlyPossibleColumn() {
        #expect(WindowMatcher.optimalAssignment([[nil, 5], [nil, nil]], colCount: 2) == [1, nil])
        #expect(WindowMatcher.greedyAssignment([[nil, 5], [nil, nil]], colCount: 2) == [1, nil])
    }
}
