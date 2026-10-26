import XCTest
@testable import WMCore

final class SwipeRecognizerTests: XCTestCase {
    private func touch(_ id: Int32, _ x: Double, _ y: Double = 0.5, state: Int32 = 4) -> TouchPoint {
        TouchPoint(state: state, fingerID: id, x: x, y: y)
    }

    /// `n` fingers spread apart, all moved by (dx, dy).
    private func frame(_ t: Double, fingers n: Int = 3, dx: Double = 0, dy: Double = 0) -> TouchFrame {
        TouchFrame(timestamp: t, touches: (0..<n).map { touch(Int32($0 + 1), 0.4 + 0.05 * Double($0) + dx, 0.5 + dy) })
    }

    private func lifted(_ t: Double) -> TouchFrame { TouchFrame(timestamp: t, touches: []) }

    /// Runs a drag of 10 frames over `duration` seconds and collects events.
    private func drag(_ r: inout ThreeFingerSwipeRecognizer, start: Double, fingers: Int = 3,
                      dx: Double, dy: Double = 0, duration: Double = 0.3) -> [ThreeFingerSwipeEvent] {
        var events: [ThreeFingerSwipeEvent] = []
        for i in 0...10 {
            let f = Double(i) / 10
            if let e = r.feed(frame(start + duration * f, fingers: fingers, dx: dx * f, dy: dy * f)) { events.append(e) }
        }
        return events
    }

    func testCleanSwipeRight() {
        var r = ThreeFingerSwipeRecognizer()
        let events = drag(&r, start: 0, dx: 0.4)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.swipe, .swipeRight)
        XCTAssertGreaterThan(events.first?.velocity ?? 0, 0.15)
    }

    func testCleanSwipeLeft() {
        var r = ThreeFingerSwipeRecognizer()
        let events = drag(&r, start: 0, dx: -0.4)
        XCTAssertEqual(events.map(\.swipe), [.swipeLeft])
        XCTAssertLessThan(events[0].travel, 0)
    }

    func testTooShortDoesNotFire() {
        var r = ThreeFingerSwipeRecognizer()
        XCTAssertTrue(drag(&r, start: 0, dx: 0.2).isEmpty)
    }

    func testVerticalDoesNotFire() {
        var r = ThreeFingerSwipeRecognizer()
        XCTAssertTrue(drag(&r, start: 0, dx: 0.05, dy: 0.5).isEmpty)
    }

    func testDiagonalDoesNotFire() {
        var r = ThreeFingerSwipeRecognizer()
        XCTAssertTrue(drag(&r, start: 0, dx: 0.4, dy: 0.3).isEmpty)
    }

    func testTooSlowDoesNotFire() {
        var r = ThreeFingerSwipeRecognizer()
        XCTAssertTrue(drag(&r, start: 0, dx: 0.4, duration: 3).isEmpty)
    }

    func testTwoFingersIgnored() {
        var r = ThreeFingerSwipeRecognizer()
        XCTAssertTrue(drag(&r, start: 0, fingers: 2, dx: 0.5).isEmpty)
    }

    func testFourFingersIgnored() {
        var r = ThreeFingerSwipeRecognizer()
        XCTAssertTrue(drag(&r, start: 0, fingers: 4, dx: 0.5).isEmpty)
    }

    func testFingerCountChangingMidGestureCancels() {
        var r = ThreeFingerSwipeRecognizer()
        var events: [ThreeFingerSwipeEvent] = []
        events += [r.feed(frame(0, dx: 0))].compactMap { $0 }
        events += [r.feed(frame(0.1, dx: 0.1))].compactMap { $0 }
        // A fourth finger lands, then travel continues with three again.
        events += [r.feed(frame(0.15, fingers: 4, dx: 0.15))].compactMap { $0 }
        events += [r.feed(frame(0.2, dx: 0.3))].compactMap { $0 }
        events += [r.feed(frame(0.25, dx: 0.5))].compactMap { $0 }
        XCTAssertTrue(events.isEmpty)
    }

    func testTwoThenThreeFingersLandingStillWorks() {
        var r = ThreeFingerSwipeRecognizer()
        XCTAssertNil(r.feed(frame(0, fingers: 2)))
        var events: [ThreeFingerSwipeEvent] = []
        for i in 0...10 {
            let f = Double(i) / 10
            if let e = r.feed(frame(0.05 + 0.3 * f, dx: 0.4 * f)) { events.append(e) }
        }
        XCTAssertEqual(events.map(\.swipe), [.swipeRight])
    }

    func testReplacedFingerCancels() {
        var r = ThreeFingerSwipeRecognizer()
        XCTAssertNil(r.feed(frame(0)))
        let swapped = TouchFrame(timestamp: 0.2, touches: [touch(1, 0.7), touch(2, 0.75), touch(9, 0.8)])
        XCTAssertNil(r.feed(swapped))
        XCTAssertNil(r.feed(frame(0.3, dx: 0.5)))
    }

    func testFiresOncePerGesture() {
        var r = ThreeFingerSwipeRecognizer()
        var events = drag(&r, start: 0, dx: 0.4)
        // Fingers keep moving after the swipe fired.
        for i in 1...5 { if let e = r.feed(frame(0.3 + Double(i) * 0.05, dx: 0.4 + Double(i) * 0.1)) { events.append(e) } }
        XCTAssertEqual(events.count, 1)
    }

    func testRepeatedGestureAfterLift() {
        var r = ThreeFingerSwipeRecognizer()
        XCTAssertEqual(drag(&r, start: 0, dx: 0.4).count, 1)
        XCTAssertNil(r.feed(lifted(0.5)))
        XCTAssertEqual(drag(&r, start: 1.0, dx: -0.4).map(\.swipe), [.swipeLeft])
    }

    func testCooldownDebouncesQuickRepeat() {
        var r = ThreeFingerSwipeRecognizer()
        XCTAssertEqual(drag(&r, start: 0, dx: 0.4, duration: 0.2).count, 1)
        XCTAssertNil(r.feed(lifted(0.21)))
        // Lands again 20 ms later and swipes quickly: still inside the 0.3 s cooldown of the first fire.
        XCTAssertTrue(drag(&r, start: 0.22, dx: 0.4, duration: 0.05).isEmpty)
        XCTAssertNil(r.feed(lifted(0.4)))
        XCTAssertEqual(drag(&r, start: 1.0, dx: 0.4).count, 1)
    }

    func testLockedGestureNeedsFullLiftNotJustCountChange() {
        var r = ThreeFingerSwipeRecognizer()
        XCTAssertNil(r.feed(frame(0, fingers: 4)))
        // Down to three fingers while still touching: stays ignored.
        XCTAssertTrue(drag(&r, start: 0.1, dx: 0.5).isEmpty)
        XCTAssertNil(r.feed(lifted(1)))
        XCTAssertEqual(drag(&r, start: 2, dx: 0.5).count, 1)
    }

    func testInjectedConfiguration() {
        var r = ThreeFingerSwipeRecognizer(configuration: .init(fingers: 2, minTravel: 0.1))
        XCTAssertEqual(drag(&r, start: 0, fingers: 2, dx: 0.2).count, 1)
        var strict = ThreeFingerSwipeRecognizer(configuration: .init(minTravel: 0.6))
        XCTAssertTrue(drag(&strict, start: 0, dx: 0.4).isEmpty)
    }

    func testHoverAndLingerTouchesAreNotCounted() {
        var r = ThreeFingerSwipeRecognizer()
        let touches = [touch(1, 0.4), touch(2, 0.45), touch(3, 0.5), touch(4, 0.9, state: 2)]
        XCTAssertNil(r.feed(TouchFrame(timestamp: 0, touches: touches)))
        let moved = [touch(1, 0.8), touch(2, 0.85), touch(3, 0.9), touch(4, 0.9, state: 2)]
        XCTAssertEqual(r.feed(TouchFrame(timestamp: 0.3, touches: moved))?.swipe, .swipeRight)
    }

    func testMappingNaturalScroll() {
        let natural = SwipeWorkspaceMapping()
        XCTAssertEqual(natural.command(for: .swipeRight), .previous)
        XCTAssertEqual(natural.command(for: .swipeLeft), .next)
        let inverted = SwipeWorkspaceMapping(naturalScroll: false)
        XCTAssertEqual(inverted.command(for: .swipeRight), .next)
        XCTAssertEqual(inverted.command(for: .swipeLeft), .previous)
    }
}
