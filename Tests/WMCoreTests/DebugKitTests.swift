import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite struct DebugKitTests {
    static let te = "com.apple.TextEdit"
    let want = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test func toleranceEdges() {
        #expect(DebugVerify.framesMatch(want, want.offsetBy(dx: 4, dy: -4)))
        #expect(!DebugVerify.framesMatch(want, want.offsetBy(dx: 5, dy: 0)))
        #expect(!DebugVerify.framesMatch(want, CGRect(x: 100, y: 100, width: 805, height: 600)))
    }

    @Test func clampedMeansBiggerThanAsked() {
        let big = CGRect(x: 100, y: 100, width: 900, height: 600)
        #expect(DebugVerify.isClamped(actual: big, wanted: want))
        #expect(!DebugVerify.isClamped(actual: want, wanted: want))
        #expect(!DebugVerify.isClamped(actual: big.offsetBy(dx: 50, dy: 0), wanted: want))
    }

    @Test func passesWhenPlaced() {
        let live = [DebugLiveWindow(windowID: 1, bundleID: Self.te, frame: want, desktop: 2)]
        let e = DebugExpectation(label: "A", bundleID: Self.te, frame: want, desktop: 2)
        let checks = DebugVerify.evaluate(expectations: [e], live: live)
        #expect(checks.allSatisfy { $0.passed })
        #expect(checks.count >= 5)
    }

    @Test func failsOnWrongFrameDesktopAndState() {
        let live = [DebugLiveWindow(windowID: 1, bundleID: Self.te, frame: want.offsetBy(dx: 200, dy: 200),
                                    desktop: 1, isMinimized: true, isAppHidden: true)]
        let e = DebugExpectation(label: "A", bundleID: Self.te, frame: want, desktop: 2)
        let failed = DebugVerify.evaluate(expectations: [e], live: live).filter { !$0.passed }.map(\.id)
        #expect(failed.count == 4)
    }

    @Test func missingWindowFails() {
        let e = DebugExpectation(label: "A", bundleID: Self.te, frame: want)
        let checks = DebugVerify.evaluate(expectations: [e], live: [])
        #expect(checks.count == 1 && !checks[0].passed)
    }

    @Test func duplicatesAreNotSwapped() {
        let left = CGRect(x: 0, y: 25, width: 600, height: 500)
        let right = CGRect(x: 700, y: 25, width: 600, height: 500)
        let es = [DebugExpectation(label: "L", bundleID: Self.te, frame: left),
                  DebugExpectation(label: "R", bundleID: Self.te, frame: right)]
        let ok = [DebugLiveWindow(windowID: 9, bundleID: Self.te, frame: right),
                  DebugLiveWindow(windowID: 8, bundleID: Self.te, frame: left)]
        #expect(DebugVerify.evaluate(expectations: es, live: ok).allSatisfy { $0.passed })
        // Two windows stacked on one spot: only one can satisfy its expectation.
        let swapped = [DebugLiveWindow(windowID: 9, bundleID: Self.te, frame: left),
                       DebugLiveWindow(windowID: 8, bundleID: Self.te, frame: left)]
        #expect(!DebugVerify.evaluate(expectations: es, live: swapped).allSatisfy { $0.passed })
    }

    @Test func extrasMustStay() {
        let x = DebugExtra(windowID: 5, label: "C", frame: want, desktop: 1)
        let same = [DebugLiveWindow(windowID: 5, bundleID: Self.te, frame: want, desktop: 1)]
        #expect(DebugVerify.evaluate(expectations: [], live: same, extras: [x]).allSatisfy { $0.passed })
        let moved = [DebugLiveWindow(windowID: 5, bundleID: Self.te, frame: want.offsetBy(dx: 30, dy: 0), desktop: 1)]
        #expect(!DebugVerify.evaluate(expectations: [], live: moved, extras: [x])[0].passed)
        #expect(!DebugVerify.evaluate(expectations: [], live: [], extras: [x])[0].passed)
    }

    @Test func clampedPasses() {
        let big = CGRect(x: 100, y: 100, width: 900, height: 600)
        let live = [DebugLiveWindow(windowID: 1, bundleID: Self.te, frame: big)]
        let e = DebugExpectation(label: "A", bundleID: Self.te, frame: want)
        #expect(DebugVerify.evaluate(expectations: [e], live: live).allSatisfy { $0.passed })
    }

    @Test func scenarioMetadata() {
        for s in DebugScenarioID.allCases { #expect(!s.title.isEmpty && !s.summary.isEmpty) }
    }
}
