import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Tests for the pure parts of WindowMover (planning, tolerance, judging, Chromium detection) and for the
/// placement loop run against a fake window. No real window is ever touched.
@Suite struct WindowMoverTests {
    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: plan

    @Test func planIsEmptyWhenFrameAlreadyMatches() {
        let frame = Self.rect(100, 50, 800, 600)
        #expect(WindowMover.plan(current: frame, target: frame).isEmpty)
    }

    @Test func planSkipsDifferencesWithinTolerance() {
        let current = Self.rect(100, 50, 800, 600)
        // Exactly 1 point off in every value still counts as "there".
        #expect(WindowMover.plan(current: current, target: Self.rect(101, 49, 799, 601)).isEmpty)
        // A little more does not.
        #expect(WindowMover.plan(current: current, target: Self.rect(101.5, 50, 800, 600)) == [.position])
    }

    @Test func planUsesOnlyPositionWhenSizeMatches() {
        #expect(WindowMover.plan(current: Self.rect(0, 0, 800, 600), target: Self.rect(300, 200, 800, 600)) == [.position])
    }

    @Test func planUsesOnlySizeWhenPositionMatches() {
        #expect(WindowMover.plan(current: Self.rect(0, 0, 800, 600), target: Self.rect(0, 0, 400, 300)) == [.size])
        // One dimension is enough.
        #expect(WindowMover.plan(current: Self.rect(0, 0, 800, 600), target: Self.rect(0, 0, 800, 303)) == [.size])
    }

    @Test func planIsSizePositionSizeWhenBothDiffer() {
        #expect(WindowMover.plan(current: Self.rect(0, 0, 800, 600), target: Self.rect(-1440, 25, 1440, 875))
            == [.size, .position, .size])
    }

    @Test func planHonoursACustomTolerance() {
        let current = Self.rect(0, 0, 800, 600)
        let target = Self.rect(4, 4, 804, 604)
        #expect(WindowMover.plan(current: current, target: target, tolerance: 5).isEmpty)
        #expect(WindowMover.plan(current: current, target: target, tolerance: 3) == [.size, .position, .size])
    }

    @Test func retryPlanMovesBeforeResizing() {
        let target = Self.rect(100, 100, 500, 400)
        #expect(WindowMover.retryPlan(current: Self.rect(0, 0, 900, 700), target: target) == [.position, .size])
        #expect(WindowMover.retryPlan(current: Self.rect(100, 100, 900, 700), target: target) == [.size])
        #expect(WindowMover.retryPlan(current: Self.rect(0, 0, 500, 400), target: target) == [.position])
        #expect(WindowMover.retryPlan(current: target, target: target).isEmpty)
    }

    // MARK: tolerance

    @Test func toleranceBoundaryIsInclusive() {
        let a = Self.rect(10, 10, 100, 100)
        #expect(WindowMover.frameMatches(a, Self.rect(11, 9, 101, 99)))
        #expect(!WindowMover.frameMatches(a, Self.rect(11.01, 10, 100, 100)))
        #expect(!WindowMover.frameMatches(a, Self.rect(10, 10, 100, 101.5)))
        #expect(WindowMover.positionMatches(CGPoint(x: 0, y: 0), CGPoint(x: 1, y: -1)))
        #expect(!WindowMover.positionMatches(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 2)))
        #expect(WindowMover.sizeMatches(CGSize(width: 10, height: 10), CGSize(width: 9, height: 11)))
        #expect(!WindowMover.sizeMatches(CGSize(width: 10, height: 10), CGSize(width: 12, height: 10)))
    }

    @Test func verdictTellsMinimumSizeFromRefusal() {
        let requested = Self.rect(100, 100, 200, 100)
        // Exactly as asked.
        var v = WindowMover.verdict(requested: requested, actual: requested)
        #expect(!v.minSizeHit && !v.refused)
        // Window is larger than asked (minimum size) but at the right place.
        v = WindowMover.verdict(requested: requested, actual: Self.rect(100, 100, 400, 300))
        #expect(v.minSizeHit && !v.refused)
        // Window is smaller than asked (maximum size or screen clamp): refused.
        v = WindowMover.verdict(requested: requested, actual: Self.rect(100, 100, 150, 100))
        #expect(!v.minSizeHit && v.refused)
        // Wrong place: refused.
        v = WindowMover.verdict(requested: requested, actual: Self.rect(0, 0, 200, 100))
        #expect(!v.minSizeHit && v.refused)
        // Minimum size pushed the window out of place: both.
        v = WindowMover.verdict(requested: requested, actual: Self.rect(100, 40, 400, 300))
        #expect(v.minSizeHit && v.refused)
        // No read-back at all.
        v = WindowMover.verdict(requested: requested, actual: nil)
        #expect(!v.minSizeHit && v.refused)
    }

    // MARK: Chromium detection

    @Test func chromiumBundleIDs() {
        #expect(WindowMover.isChromiumBased(bundleID: "com.google.Chrome", frameworkNames: []))
        #expect(WindowMover.isChromiumBased(bundleID: "com.google.Chrome.canary", frameworkNames: []))
        #expect(WindowMover.isChromiumBased(bundleID: "com.microsoft.edgemac.Beta", frameworkNames: []))
        #expect(WindowMover.isChromiumBased(bundleID: "com.brave.Browser", frameworkNames: []))
        #expect(WindowMover.isChromiumBased(bundleID: "company.thebrowser.Browser", frameworkNames: []))
        #expect(WindowMover.isChromiumBased(bundleID: "COM.GOOGLE.CHROME", frameworkNames: []))
    }

    @Test func nonChromiumBundleIDs() {
        #expect(!WindowMover.isChromiumBased(bundleID: "com.apple.Safari", frameworkNames: []))
        #expect(!WindowMover.isChromiumBased(bundleID: "org.mozilla.firefox", frameworkNames: []))
        #expect(!WindowMover.isChromiumBased(bundleID: "com.apple.finder"))
        #expect(!WindowMover.isChromiumBased(bundleID: nil))
        // Same prefix text but a different product must not match.
        #expect(!WindowMover.isChromiumBased(bundleID: "com.google.ChromeRemoteDesktop", frameworkNames: []))
        #expect(!WindowMover.isChromiumBased(bundleID: "com.google.Drive", frameworkNames: []))
    }

    @Test func chromiumFrameworks() {
        #expect(WindowMover.isChromiumBased(bundleID: "com.microsoft.VSCode",
                                            frameworkNames: ["Electron Framework.framework", "Mantle.framework"]))
        #expect(WindowMover.isChromiumBased(bundleID: nil, frameworkNames: ["Chromium Embedded Framework.framework"]))
        #expect(WindowMover.isChromiumBased(bundleID: nil, frameworkNames: ["Google Chrome Framework"]))
        #expect(WindowMover.isChromiumBased(bundleID: nil, frameworkNames: ["Google Chrome for Testing Framework.framework"]))
        #expect(WindowMover.isChromiumBased(bundleID: nil, frameworkNames: ["Microsoft Edge Framework.framework"]))
        #expect(!WindowMover.isChromiumBased(bundleID: "com.apple.Notes", frameworkNames: ["Sparkle.framework", "Foo.framework"]))
        #expect(!WindowMover.isChromiumBased(bundleID: nil, frameworkNames: []))
    }

    // MARK: Placement loop against a fake window

    @Test func alreadyPlacedWindowGetsNoWrites() {
        let frame = Self.rect(100, 100, 800, 600)
        let window = FakeWindow(frame: frame)
        var announced = false
        let result = WindowMover.apply(window, requested: frame, options: Self.quiet, beforeFirstWrite: { announced = true })
        #expect(result.steps.isEmpty)
        #expect(result.matched)
        #expect(result.actual == frame)
        #expect(window.writeLog.isEmpty)
        #expect(!announced)
    }

    @Test func movesAndResizesWithSizePositionSize() {
        let window = FakeWindow(frame: Self.rect(0, 0, 800, 600))
        let target = Self.rect(200, 100, 500, 400)
        var announced = 0
        let result = WindowMover.apply(window, requested: target, options: Self.quiet, beforeFirstWrite: { announced += 1 })
        #expect(result.steps.map(\.write) == [.size, .position, .size])
        #expect(result.matched)
        #expect(!result.retried)
        #expect(window.frame == target)
        #expect(announced == 1)
    }

    @Test func minimumSizeIsReportedNotRetriedForever() {
        let window = FakeWindow(frame: Self.rect(0, 0, 800, 600))
        window.minSize = CGSize(width: 400, height: 300)
        let target = Self.rect(50, 50, 200, 100)
        let result = WindowMover.apply(window, requested: target, options: Self.quiet)
        #expect(result.minSizeHit)
        #expect(!result.refused)
        #expect(!result.matched)
        #expect(result.actual == Self.rect(50, 50, 400, 300))
        // First pass sizes and moves; the retry pass only asks for the size again.
        #expect(result.steps.map(\.write) == [.size, .position, .size, .size])
        #expect(result.steps.filter(\.isRetry).count == 1)
    }

    @Test func zeroRetriesStopsAfterFirstPass() {
        let window = FakeWindow(frame: Self.rect(0, 0, 800, 600))
        window.minSize = CGSize(width: 400, height: 300)
        var options = Self.quiet
        options.retries = 0
        let result = WindowMover.apply(window, requested: Self.rect(50, 50, 200, 100), options: options)
        #expect(result.minSizeHit)
        #expect(!result.retried)
    }

    @Test func retryRepairsAPositionTheFirstPassMissed() {
        let window = FakeWindow(frame: Self.rect(0, 0, 800, 600))
        window.ignoreFirst[.position] = 1   // the app drops the first position write
        let target = Self.rect(300, 200, 500, 400)
        let result = WindowMover.apply(window, requested: target, options: Self.quiet)
        #expect(result.matched)
        #expect(result.retried)
        #expect(window.frame == target)
        // Retry moves first, and only what is still wrong.
        #expect(result.steps.filter(\.isRetry).map(\.write) == [.position])
    }

    @Test func refusedSizeIsReportedAfterTheRetry() {
        let window = FakeWindow(frame: Self.rect(0, 0, 800, 600))
        window.maxSize = CGSize(width: 600, height: 500)   // cannot grow past this, whatever is asked
        let target = Self.rect(10, 10, 1000, 700)
        let result = WindowMover.apply(window, requested: target, options: Self.quiet)
        #expect(result.refused)
        #expect(!result.minSizeHit)
        #expect(result.retried)
        #expect(result.actual?.size == CGSize(width: 600, height: 500))
    }

    @Test func fixedSizeWindowStillMoves() {
        let window = FakeWindow(frame: Self.rect(0, 0, 800, 600))
        window.sizeError = .attributeUnsupported   // size is not settable
        let result = WindowMover.apply(window, requested: Self.rect(300, 200, 400, 300), options: Self.quiet)
        #expect(result.refused)   // the size is not what was asked for
        #expect(!result.minSizeHit)   // a rejected write is a refusal, not a minimum size
        #expect(window.frame.origin == CGPoint(x: 300, y: 200))
        // The failed size write is tried once and then given up, so the loop cannot spin on it.
        #expect(result.steps.filter { $0.write == .size }.count == 1)
        #expect(result.steps.first?.succeeded == false)
    }

    @Test func goneWindowStopsAtOnce() {
        let window = FakeWindow(frame: Self.rect(0, 0, 800, 600))
        window.sizeError = .invalidUIElement
        let result = WindowMover.apply(window, requested: Self.rect(300, 200, 400, 300), options: Self.quiet)
        #expect(result.steps.count == 1)
        #expect(window.frame == Self.rect(0, 0, 800, 600))
        #expect(result.refused)
    }

    @Test func unreadableFrameIsRefusedWithoutWrites() {
        let window = FakeWindow(frame: .zero)
        window.readable = false
        let result = WindowMover.apply(window, requested: Self.rect(0, 0, 100, 100), options: Self.quiet)
        #expect(result.refused)
        #expect(result.actual == nil)
        #expect(result.initial == nil)
        #expect(window.writeLog.isEmpty)
    }

    @Test func settleWaitsForALateWindow() {
        let window = FakeWindow(frame: Self.rect(0, 0, 800, 600))
        window.appliesAfterReads = 1   // the first read after the writes still shows the old frame
        var options = FrameMoveOptions()
        options.settleTimeout = 0.5
        options.settleInterval = 0.01
        var slept: TimeInterval = 0
        let target = Self.rect(100, 100, 400, 300)
        let result = WindowMover.apply(window, requested: target, options: options, sleep: { slept += $0 })
        #expect(result.matched)
        #expect(!result.retried)
        #expect(slept > 0)
    }

    private static var quiet: FrameMoveOptions {
        var options = FrameMoveOptions()
        options.settleTimeout = 0
        return options
    }
}

/// A window that follows simple rules: optional min / max size, dropped writes, delayed effect.
private final class FakeWindow: WindowMover.FrameAccess {
    /// The truth. What `readFrame` shows can lag behind it (see `appliesAfterReads`).
    var frame: CGRect
    var minSize = CGSize.zero
    var maxSize = CGSize(width: 100_000, height: 100_000)
    var sizeError: AXError = .success
    var readable = true
    /// Number of writes of a kind to drop silently (the call reports success but nothing changes).
    var ignoreFirst: [FrameWrite: Int] = [:]
    /// After a write, this many reads still show the old frame.
    var appliesAfterReads = 0
    var writeLog: [FrameWrite] = []
    private var visible: CGRect
    private var staleReads = 0

    init(frame: CGRect) {
        self.frame = frame
        self.visible = frame
    }

    func readFrame() -> CGRect? {
        guard readable else { return nil }
        if staleReads > 0 {
            staleReads -= 1
        } else {
            visible = frame
        }
        return visible
    }

    func writeSize(_ size: CGSize) -> AXError {
        writeLog.append(.size)
        if sizeError != .success { return sizeError }
        if consumeIgnore(.size) { return .success }
        frame.size = CGSize(width: min(max(size.width, minSize.width), maxSize.width),
                            height: min(max(size.height, minSize.height), maxSize.height))
        staleReads = appliesAfterReads
        return .success
    }

    func writePosition(_ point: CGPoint) -> AXError {
        writeLog.append(.position)
        if consumeIgnore(.position) { return .success }
        frame.origin = point
        staleReads = appliesAfterReads
        return .success
    }

    private func consumeIgnore(_ write: FrameWrite) -> Bool {
        guard let left = ignoreFirst[write], left > 0 else { return false }
        ignoreFirst[write] = left - 1
        return true
    }
}

/// Event kinds of the observer hub map to AX notification names and back.
@Suite struct AXHubEventKindTests {
    @Test func notificationNamesRoundTrip() {
        for kind in AXHubEvent.Kind.axKinds {
            let name = kind.notificationName
            #expect(name != nil)
            #expect(AXHubEvent.Kind(notification: name ?? "") == kind)
        }
    }

    @Test func nonAXKindsHaveNoNotification() {
        for kind in [AXHubEvent.Kind.appLaunched, .appTerminated, .windowDiscovered] {
            #expect(kind.notificationName == nil)
        }
        #expect(AXHubEvent.Kind(notification: "AXSomethingElse") == nil)
    }

    @Test func windowLevelSplit() {
        #expect(AXHubEvent.Kind.windowCreated.isWindowLevel == false)
        #expect(AXHubEvent.Kind.focusedWindowChanged.isWindowLevel == false)
        #expect(AXHubEvent.Kind.windowMoved.isWindowLevel)
        #expect(AXHubEvent.Kind.windowDestroyed.isWindowLevel)
        #expect(AXHubEvent.Kind.titleChanged.isWindowLevel)
    }

    @Test func hubStartsEmptyAndStopsSafely() {
        let hub = AXObserverHub()
        #expect(hub.observedPIDs.isEmpty)
        // Stopping something that was never started, or a pid that does not exist, must not crash.
        hub.stop(pid: 999_999)
        hub.stopAll()
        #expect(hub.start(pid: 999_999) != .success)
        #expect(!hub.isObserving(pid: 999_999))
        hub.shutdown()
    }
}
