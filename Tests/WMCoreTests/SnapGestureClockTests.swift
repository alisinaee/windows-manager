import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite struct SnapGestureClockTests {
    @Test func advanceMakesOlderIdsStale() {
        var clock = SnapGestureClock()
        let first = clock.advance()
        #expect(clock.isCurrent(first))
        let second = clock.advance()
        #expect(!clock.isCurrent(first))
        #expect(clock.isCurrent(second))
    }

    @Test func onlyOneFrameReadPerGesture() {
        var clock = SnapGestureClock()
        let id = clock.advance()
        let firstRead = clock.beginFrameRead(for: id)
        let secondRead = clock.beginFrameRead(for: id)
        #expect(firstRead)
        #expect(!secondRead)
        clock.finishFrameRead(for: id)
        let afterFinish = clock.beginFrameRead(for: id)
        #expect(afterFinish)
    }

    @Test func staleGestureNeverStartsARead() {
        var clock = SnapGestureClock()
        let old = clock.advance()
        _ = clock.advance()
        let started = clock.beginFrameRead(for: old)
        #expect(!started)
        #expect(clock.frameReadInFlight == nil)
    }

    @Test func newGestureMayReadWhileOldReadIsStillInFlight() {
        var clock = SnapGestureClock()
        let old = clock.advance()
        let oldRead = clock.beginFrameRead(for: old)
        #expect(oldRead)
        let new = clock.advance()
        // The old result arrives late: it must not clear the flag of the new gesture.
        clock.finishFrameRead(for: old)
        let newRead = clock.beginFrameRead(for: new)
        #expect(newRead)
    }

    @Test func dragThresholdIsInclusiveAndUsesDistance() {
        let press = CGPoint(x: 100, y: 100)
        #expect(!SnapGestureClock.passedDragThreshold(from: press, to: CGPoint(x: 104, y: 104), minimumDistance: 8))
        #expect(SnapGestureClock.passedDragThreshold(from: press, to: CGPoint(x: 108, y: 100), minimumDistance: 8))
        #expect(SnapGestureClock.passedDragThreshold(from: press, to: CGPoint(x: 106, y: 106), minimumDistance: 8))
    }
}
