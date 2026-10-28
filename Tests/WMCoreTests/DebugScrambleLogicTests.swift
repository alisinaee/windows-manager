import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite struct DebugScrambleLogicTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let external = CGRect(x: 1440, y: -200, width: 1920, height: 1080)

    @Test func offScreenFrameKeepsNegativeOrigin() {
        let frame = ScrambleMath.offScreenFrame(origin: CGPoint(x: -2400, y: -1600), size: CGSize(width: 800, height: 600))
        #expect(frame.origin == CGPoint(x: -2400, y: -1600))
        #expect(frame.size == CGSize(width: 800, height: 600))
    }

    @Test func entirelyOffScreenOnlyWhenNoDisplayTouched() {
        let far = CGRect(x: -2400, y: -1600, width: 800, height: 600)
        #expect(ScrambleMath.isEntirelyOffScreen(far, displays: [screen, external]))
        // Partly on screen: not off-screen.
        let edge = CGRect(x: -100, y: 50, width: 800, height: 600)
        #expect(!ScrambleMath.isEntirelyOffScreen(edge, displays: [screen, external]))
        // Sitting on the second display.
        let second = CGRect(x: 1600, y: 100, width: 400, height: 300)
        #expect(!ScrambleMath.isEntirelyOffScreen(second, displays: [screen, external]))
        // No displays at all: nothing can be on one.
        #expect(ScrambleMath.isEntirelyOffScreen(far, displays: []))
    }

    @Test func halfSizeHalvesAndKeepsMinimum() {
        #expect(ScrambleMath.halfSize(of: CGSize(width: 1200, height: 900)) == CGSize(width: 600, height: 450))
        // Small windows are clamped to the minimum used by the shifted-window scramble.
        #expect(ScrambleMath.halfSize(of: CGSize(width: 400, height: 300)) == CGSize(width: 300, height: 250))
        // Odd sizes round down.
        #expect(ScrambleMath.halfSize(of: CGSize(width: 1001, height: 1001)) == CGSize(width: 500, height: 500))
    }

    @Test func sizeAcceptedWithinFourPoints() {
        let want = CGSize(width: 960, height: 1015)
        #expect(ScrambleMath.sizeAccepted(requested: want, actual: CGSize(width: 960, height: 1011)))
        #expect(ScrambleMath.sizeAccepted(requested: want, actual: CGSize(width: 964, height: 1015)))
        #expect(!ScrambleMath.sizeAccepted(requested: want, actual: CGSize(width: 960, height: 900)))
        #expect(!ScrambleMath.sizeAccepted(requested: want, actual: CGSize(width: 385, height: 616)))
    }

    @Test func positionMatchesWithinTolerance() {
        #expect(ScrambleMath.positionMatches(CGPoint(x: -100, y: 50), CGPoint(x: -96, y: 54)))
        #expect(!ScrambleMath.positionMatches(CGPoint(x: -100, y: 50), CGPoint(x: -95, y: 50)))
    }

    @Test func parsePairReadsAppleScriptLists() {
        #expect(ScrambleMath.parsePair("960, 900\n")?.0 == 960)
        #expect(ScrambleMath.parsePair("960, 900\n")?.1 == 900)
        #expect(ScrambleMath.parsePair("{-1800, -1200}")?.0 == -1800)
        #expect(ScrambleMath.parsePair("{-1800, -1200}")?.1 == -1200)
        #expect(ScrambleMath.parsePair("") == nil)
        #expect(ScrambleMath.parsePair("960") == nil)
        #expect(ScrambleMath.parsePair("a, b") == nil)
        #expect(ScrambleMath.parsePair("1, 2, 3") == nil)
    }

    @Test func parseCountAndBool() {
        #expect(ScrambleMath.parseCount("3\n") == 3)
        #expect(ScrambleMath.parseCount("0") == 0)
        #expect(ScrambleMath.parseCount("missing value") == nil)
        #expect(ScrambleMath.parseBool("true\n") == true)
        #expect(ScrambleMath.parseBool("False") == false)
        #expect(ScrambleMath.parseBool("") == nil)
    }

    @Test func flagsMatchNeedsAllAndAtLeastOne() {
        #expect(ScrambleMath.flagsMatch("true, true\n", expected: true))
        #expect(ScrambleMath.flagsMatch("{false, false}", expected: false))
        #expect(!ScrambleMath.flagsMatch("true, false", expected: true))
        #expect(!ScrambleMath.flagsMatch("", expected: true))
        #expect(!ScrambleMath.flagsMatch("missing value", expected: false))
    }

    @Test func scriptFailureDetection() {
        #expect(ScrambleMath.scriptFailed("execution error: Not authorized. (-1743)"))
        #expect(ScrambleMath.scriptFailed("osascript failed: boom"))
        #expect(!ScrambleMath.scriptFailed("960, 900\n"))
        #expect(!ScrambleMath.scriptFailed(""))
    }

    @Test func escapesQuotesAndBackslashes() {
        #expect(ScrambleMath.escaped("say \"hi\"") == "say \\\"hi\\\"")
        #expect(ScrambleMath.escaped("a\\b") == "a\\\\b")
        #expect(ScrambleMath.escaped("TextEdit") == "TextEdit")
    }

    @Test func normalizedBundlesTrimsDedupesAndKeepsOrder() {
        let raw = ["com.apple.Notes", "  com.apple.Calculator ", "", "com.apple.Notes", "   ", "com.apple.Safari"]
        #expect(ScrambleMath.normalizedBundles(raw) == ["com.apple.Notes", "com.apple.Calculator", "com.apple.Safari"])
        #expect(ScrambleMath.normalizedBundles([]).isEmpty)
    }

    @Test func keepWaitingUntilWindowOrLimit() {
        #expect(ScrambleMath.shouldKeepWaiting(found: false, elapsed: 3, limit: 15))
        #expect(!ScrambleMath.shouldKeepWaiting(found: true, elapsed: 3, limit: 15))
        #expect(!ScrambleMath.shouldKeepWaiting(found: false, elapsed: 15, limit: 15))
    }

    @Test func firstWindowResultReportsTimeOrTimeout() {
        let ok = ScrambleMath.firstWindowResult(app: "Music", found: true, elapsed: 4.0, limit: 15)
        #expect(ok.ok)
        #expect(ok.note == "Music: first window after 4.0s")
        let late = ScrambleMath.firstWindowResult(app: "Music", found: false, elapsed: 15, limit: 15)
        #expect(!late.ok)
        #expect(late.note == "Music: no window within 15s")
    }

    @Test func createdResultNeedsEveryWindow() {
        #expect(ScrambleMath.createdResult(created: 3, wanted: 3).ok)
        #expect(!ScrambleMath.createdResult(created: 2, wanted: 3).ok)
        #expect(ScrambleMath.createdResult(created: 2, wanted: 3).note == "created 2 of 3 windows")
    }

    @Test func focusResultComparesFrontmostBundle() {
        let ok = ScrambleMath.focusResult(app: "TextEdit", frontmost: "com.apple.TextEdit", expected: "com.apple.TextEdit")
        #expect(ok.ok)
        let miss = ScrambleMath.focusResult(app: "TextEdit", frontmost: "com.apple.Terminal", expected: "com.apple.TextEdit")
        #expect(!miss.ok)
        #expect(miss.note == "frontmost is com.apple.Terminal")
        #expect(!ScrambleMath.focusResult(app: "TextEdit", frontmost: nil, expected: "com.apple.TextEdit").ok)
    }

    @Test func preOpenResultFailsWhenAnyAppMissing() {
        let all = ScrambleMath.preOpenResult(wanted: 3, missing: [])
        #expect(all.ok)
        #expect(all.note == "pre-opened 3 of 3")
        let some = ScrambleMath.preOpenResult(wanted: 3, missing: ["com.example.Gone"])
        #expect(!some.ok)
        #expect(some.note == "pre-opened 2 of 3; not installed: com.example.Gone")
        #expect(!ScrambleMath.preOpenResult(wanted: 0, missing: []).ok)
    }
}
