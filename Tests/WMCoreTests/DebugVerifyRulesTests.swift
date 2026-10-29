import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite struct DebugVerifyRulesTests {
    let want = CGRect(x: 0, y: 0, width: 200, height: 200)
    let limit = CGSize(width: 400, height: 300)

    @Test func sizeLimitedPassesAtLearnedLimit() {
        let c = DebugVerify.sizeLimitedCheck(id: "a", label: "A", wanted: want,
                                             actual: CGRect(x: 0, y: 0, width: 402, height: 299), learnedLimit: limit)
        #expect(c.passed)
        #expect(!c.detail.contains("INCONCLUSIVE"))
    }

    @Test func sizeLimitedFailsWhenNotAtLimit() {
        let c = DebugVerify.sizeLimitedCheck(id: "a", label: "A", wanted: want,
                                             actual: CGRect(x: 0, y: 0, width: 500, height: 300), learnedLimit: limit)
        #expect(!c.passed)
    }

    @Test func sizeLimitedInconclusiveWithoutData() {
        let noLimit = DebugVerify.sizeLimitedCheck(id: "a", label: "A", wanted: want,
                                                   actual: CGRect(x: 0, y: 0, width: 500, height: 300), learnedLimit: nil)
        let noFrame = DebugVerify.sizeLimitedCheck(id: "a", label: "A", wanted: want, actual: nil, learnedLimit: limit)
        #expect(noLimit.passed && noLimit.detail.hasPrefix("INCONCLUSIVE"))
        #expect(noFrame.passed && noFrame.detail.hasPrefix("INCONCLUSIVE"))
    }

    @Test func idempotenceSameFramesPass() {
        let s: DebugFrameSnapshot = [1: want, 2: want.offsetBy(dx: 10, dy: 10)]
        let checks = DebugVerify.idempotenceChecks(first: s, second: s)
        #expect(checks.count == 2 && checks.allSatisfy { $0.passed })
    }

    @Test func idempotenceDetectsMoveAndDisappearance() {
        let first: DebugFrameSnapshot = [1: want, 2: want, 3: want]
        let second: DebugFrameSnapshot = [1: want.offsetBy(dx: 50, dy: 0), 2: want, 4: want]
        let checks = DebugVerify.idempotenceChecks(first: first, second: second)
        #expect(checks.filter { !$0.passed }.count == 3)
        #expect(checks.first { $0.id == "idem-2" }?.passed == true)
    }

    @Test func idempotenceInconclusiveWhenEmpty() {
        let checks = DebugVerify.idempotenceChecks(first: [:], second: [1: want])
        #expect(checks.count == 1 && checks[0].passed && checks[0].detail.hasPrefix("INCONCLUSIVE"))
    }

    @Test func duplicateIDsFlagged() {
        let a = DebugLiveWindow(windowID: 7, bundleID: "x", frame: want)
        let b = DebugLiveWindow(windowID: 8, bundleID: "x", frame: want)
        #expect(DebugVerify.duplicateIDChecks(live: [a, b]).allSatisfy { $0.passed })
        let bad = DebugVerify.duplicateIDChecks(live: [a, b, a])
        #expect(bad.count == 1 && !bad[0].passed && bad[0].detail.contains("7"))
    }
}
