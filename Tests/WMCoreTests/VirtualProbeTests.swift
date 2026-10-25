import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Pure tests for the Virtual mode probes: corner parking geometry, the swipe recognizer, the touch
/// decoder and small comparison helpers. No window is moved and no device is opened.
@Suite struct VirtualProbeTests {
    // MARK: parkedOrigin

    private let main = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func bottomRightKeepsOnePixelOfTheTopLeftCorner() {
        let origin = CornerParker.parkedOrigin(windowSize: CGSize(width: 800, height: 600), screenFrame: main,
                                               corner: .bottomRight)
        #expect(origin == CGPoint(x: 1439, y: 899))
    }

    @Test func bottomLeftKeepsOnePixelOfTheRightEdge() {
        let origin = CornerParker.parkedOrigin(windowSize: CGSize(width: 800, height: 600), screenFrame: main,
                                               corner: .bottomLeft)
        #expect(origin == CGPoint(x: -799, y: 899))
    }

    @Test func bottomRightDoesNotDependOnWindowSize() {
        let small = CornerParker.parkedOrigin(windowSize: CGSize(width: 100, height: 100), screenFrame: main,
                                              corner: .bottomRight)
        let large = CornerParker.parkedOrigin(windowSize: CGSize(width: 1400, height: 880), screenFrame: main,
                                              corner: .bottomRight)
        #expect(small == large)
    }

    @Test func screenWithOffsetOrigin() {
        let second = CGRect(x: 2560, y: 458, width: 1512, height: 982)
        #expect(CornerParker.parkedOrigin(windowSize: CGSize(width: 500, height: 400), screenFrame: second,
                                          corner: .bottomRight) == CGPoint(x: 4071, y: 1439))
        #expect(CornerParker.parkedOrigin(windowSize: CGSize(width: 500, height: 400), screenFrame: second,
                                          corner: .bottomLeft) == CGPoint(x: 2061, y: 1439))
    }

    @Test func screenWithNegativeOrigin() {
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        #expect(CornerParker.parkedOrigin(windowSize: CGSize(width: 640, height: 480), screenFrame: left,
                                          corner: .bottomRight) == CGPoint(x: -1, y: 879))
        #expect(CornerParker.parkedOrigin(windowSize: CGSize(width: 640, height: 480), screenFrame: left,
                                          corner: .bottomLeft) == CGPoint(x: -2559, y: 879))
    }

    @Test func parkedWindowShowsExactlyOnePixelOnItsScreen() {
        for corner in ParkCorner.allCases {
            let frame = CornerParker.parkedFrame(windowSize: CGSize(width: 900, height: 700), screenFrame: main,
                                                 corner: corner)
            #expect(frame.size == CGSize(width: 900, height: 700))
            #expect(CornerParker.overlapSize(frame, main) == CGSize(width: 1, height: 1))
        }
    }

    @Test func overlapSizeIsZeroWhenApart() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(CornerParker.overlapSize(a, CGRect(x: 50, y: 50, width: 10, height: 10)) == .zero)
    }

    // MARK: Corner choice and screens

    @Test func singleScreenPrefersBottomRight() {
        let corner = CornerParker.preferredCorner(windowSize: CGSize(width: 800, height: 600), screenFrame: main,
                                                  otherScreens: [])
        #expect(corner == .bottomRight)
    }

    @Test func neighbourOnTheRightMakesBottomLeftBetter() {
        let right = CGRect(x: 1440, y: 100, width: 1920, height: 1080)
        let corner = CornerParker.preferredCorner(windowSize: CGSize(width: 800, height: 600), screenFrame: main,
                                                  otherScreens: [right])
        #expect(corner == .bottomLeft)
    }

    @Test func neighbourOnTheLeftKeepsBottomRight() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let corner = CornerParker.preferredCorner(windowSize: CGSize(width: 800, height: 600), screenFrame: main,
                                                  otherScreens: [left])
        #expect(corner == .bottomRight)
    }

    @Test func screenIndexPicksTheScreenHoldingMostOfTheWindow() {
        let screens = [main, CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        #expect(CornerParker.screenIndex(containing: CGRect(x: 1300, y: 100, width: 800, height: 500),
                                         screens: screens) == 1)
        #expect(CornerParker.screenIndex(containing: CGRect(x: 100, y: 100, width: 800, height: 500),
                                         screens: screens) == 0)
    }

    @Test func screenIndexFallsBackToTheNearestScreen() {
        let screens = [main, CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        #expect(CornerParker.screenIndex(containing: CGRect(x: 5000, y: 0, width: 100, height: 100),
                                         screens: screens) == 1)
        #expect(CornerParker.screenIndex(containing: CGRect(x: 0, y: 0, width: 1, height: 1), screens: []) == nil)
    }

    @Test func cocoaFramesFlipToAccessibilityCoordinates() {
        // Main screen: same rect. A screen above the main one (Cocoa y = 900) sits at negative AX y.
        #expect(CornerParker.accessibilityFrame(fromCocoa: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                mainHeight: 900) == main)
        #expect(CornerParker.accessibilityFrame(fromCocoa: CGRect(x: 0, y: 900, width: 1920, height: 1080),
                                                mainHeight: 900) == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        // A shorter screen whose bottom is 458 points above the main screen's bottom, to the right.
        #expect(CornerParker.accessibilityFrame(fromCocoa: CGRect(x: 2560, y: 0, width: 1512, height: 982),
                                                mainHeight: 1440) == CGRect(x: 2560, y: 458, width: 1512, height: 982))
    }

    // MARK: Swipe recognizer

    /// Frames of `fingers` fingers spread over x, moving from `fromX` to `toX` (and `dy` in total on y).
    private func swipeFrames(fingers: Int = 3, fromX: Double, toX: Double, dy: Double = 0, steps: Int = 10,
                             startTime: Double = 0, dt: Double = 0.02) -> [TouchFrame] {
        (0...steps).map { step in
            let progress = Double(step) / Double(steps)
            let x = fromX + (toX - fromX) * progress
            let points = (0..<fingers).map { i in
                TouchPoint(state: 4, fingerID: Int32(i + 1), x: x + Double(i) * 0.05, y: 0.5 + dy * progress)
            }
            return TouchFrame(timestamp: startTime + Double(step) * dt, touches: points)
        }
    }

    private func liftFrame(at time: Double) -> TouchFrame { TouchFrame(timestamp: time, touches: []) }

    private func run(_ frames: [TouchFrame], through recognizer: inout SwipeRecognizer) -> [SwipeEvent] {
        frames.compactMap { recognizer.feed($0) }
    }

    @Test func threeFingersMovingRightGiveOneRightSwipe() {
        var recognizer = SwipeRecognizer()
        let events = run(swipeFrames(fromX: 0.2, toX: 0.6), through: &recognizer)
        #expect(events.count == 1)
        #expect(events.first?.direction == .right)
        #expect((events.first?.travel ?? 0) >= 0.12)
    }

    @Test func threeFingersMovingLeftGiveOneLeftSwipe() {
        var recognizer = SwipeRecognizer()
        let events = run(swipeFrames(fromX: 0.6, toX: 0.2), through: &recognizer)
        #expect(events.count == 1)
        #expect(events.first?.direction == .left)
        #expect((events.first?.travel ?? 0) <= -0.12)
    }

    @Test func eventFiresOnceThenWaitsForLift() {
        var recognizer = SwipeRecognizer()
        // Two long strokes in a row without lifting: still one event.
        let frames = swipeFrames(fromX: 0.1, toX: 0.8, steps: 20)
        #expect(run(frames, through: &recognizer).count == 1)
        // After all fingers lift, the next swipe is recognized again.
        _ = recognizer.feed(liftFrame(at: 1))
        let second = swipeFrames(fromX: 0.7, toX: 0.2, startTime: 2)
        let events = run(second, through: &recognizer)
        #expect(events.count == 1)
        #expect(events.first?.direction == .left)
    }

    @Test func twoAndFourFingersAreIgnored() {
        var recognizer = SwipeRecognizer()
        #expect(run(swipeFrames(fingers: 2, fromX: 0.1, toX: 0.8), through: &recognizer).isEmpty)
        _ = recognizer.feed(liftFrame(at: 1))
        #expect(run(swipeFrames(fingers: 4, fromX: 0.1, toX: 0.8, startTime: 2), through: &recognizer).isEmpty)
    }

    @Test func shortMovementIsIgnored() {
        var recognizer = SwipeRecognizer()
        #expect(run(swipeFrames(fromX: 0.40, toX: 0.48), through: &recognizer).isEmpty)
    }

    @Test func verticalMovementIsIgnored() {
        var recognizer = SwipeRecognizer()
        #expect(run(swipeFrames(fromX: 0.4, toX: 0.42, dy: 0.5), through: &recognizer).isEmpty)
    }

    @Test func steepDiagonalIsIgnored() {
        var recognizer = SwipeRecognizer()
        #expect(run(swipeFrames(fromX: 0.2, toX: 0.4, dy: 0.2), through: &recognizer).isEmpty)
    }

    @Test func shallowDiagonalStillCounts() {
        var recognizer = SwipeRecognizer()
        let events = run(swipeFrames(fromX: 0.2, toX: 0.6, dy: 0.1), through: &recognizer)
        #expect(events.count == 1)
        #expect(events.first?.direction == .right)
    }

    @Test func slowDragIsIgnored() {
        var recognizer = SwipeRecognizer()
        // 0.4 of travel over 5 seconds: far too slow to be a swipe.
        let frames = swipeFrames(fromX: 0.2, toX: 0.6, steps: 10, dt: 0.5)
        #expect(run(frames, through: &recognizer).isEmpty)
    }

    @Test func extraFingerCancelsTheGesture() {
        var recognizer = SwipeRecognizer()
        var frames = swipeFrames(fromX: 0.2, toX: 0.25, steps: 2)
        // A fourth finger lands, then the hand moves far.
        frames += swipeFrames(fingers: 4, fromX: 0.25, toX: 0.8, startTime: 0.1)
        #expect(run(frames, through: &recognizer).isEmpty)
        // Going back to 3 fingers without lifting does not restart the gesture.
        #expect(run(swipeFrames(fromX: 0.2, toX: 0.8, startTime: 1), through: &recognizer).isEmpty)
        // After a full lift it works again.
        _ = recognizer.feed(liftFrame(at: 2))
        #expect(run(swipeFrames(fromX: 0.2, toX: 0.8, startTime: 3), through: &recognizer).count == 1)
    }

    @Test func liftingAFingerEarlyCancelsTheGesture() {
        var recognizer = SwipeRecognizer()
        var frames = swipeFrames(fromX: 0.2, toX: 0.25, steps: 2)
        frames += swipeFrames(fingers: 2, fromX: 0.25, toX: 0.8, startTime: 0.1)
        #expect(run(frames, through: &recognizer).isEmpty)
    }

    @Test func hoveringFingersAreNotCounted() {
        var recognizer = SwipeRecognizer()
        let frames = swipeFrames(fromX: 0.2, toX: 0.8).map { frame -> TouchFrame in
            var copy = frame
            copy.touches = copy.touches.map { point in
                var p = point
                p.state = 2 // hover in range
                return p
            }
            return copy
        }
        #expect(run(frames, through: &recognizer).isEmpty)
    }

    @Test func customConfigurationChangesFingerCountAndTravel() {
        var recognizer = SwipeRecognizer(configuration: .init(fingers: 4, minTravel: 0.3))
        #expect(run(swipeFrames(fingers: 4, fromX: 0.2, toX: 0.4), through: &recognizer).isEmpty)
        _ = recognizer.feed(liftFrame(at: 1))
        let events = run(swipeFrames(fingers: 4, fromX: 0.1, toX: 0.6, startTime: 2), through: &recognizer)
        #expect(events.count == 1)
    }

    // MARK: Touch decoding

    /// Writes one MTTouch-shaped record: only the fields the decoder reads.
    private func write(_ buffer: UnsafeMutableRawPointer, index: Int, state: Int32, fingerID: Int32,
                       x: Float, y: Float, vx: Float, vy: Float) {
        let record = buffer + index * TrackpadReader.Layout.stride
        record.storeBytes(of: state, toByteOffset: TrackpadReader.Layout.state, as: Int32.self)
        record.storeBytes(of: fingerID, toByteOffset: TrackpadReader.Layout.fingerID, as: Int32.self)
        record.storeBytes(of: x, toByteOffset: TrackpadReader.Layout.positionX, as: Float.self)
        record.storeBytes(of: y, toByteOffset: TrackpadReader.Layout.positionY, as: Float.self)
        record.storeBytes(of: vx, toByteOffset: TrackpadReader.Layout.velocityX, as: Float.self)
        record.storeBytes(of: vy, toByteOffset: TrackpadReader.Layout.velocityY, as: Float.self)
    }

    @Test func touchRecordLayoutMatchesTheCStruct() {
        // int frame; double timestamp; int pathIndex, state, fingerID, handID; 4 floats normalized vector;
        // float zTotal; int field9; 3 floats; 4 floats absolute vector; 2 ints; float zDensity = 96 bytes.
        #expect(TrackpadReader.Layout.stride == 96)
        #expect(TrackpadReader.Layout.timestamp == 8)
        #expect(TrackpadReader.Layout.state == 20)
        #expect(TrackpadReader.Layout.fingerID == 24)
        #expect(TrackpadReader.Layout.positionX == 32)
        #expect(TrackpadReader.Layout.velocityY == 44)
    }

    @Test func decodesTouchRecordsFromARawBuffer() {
        let count = 3
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: count * TrackpadReader.Layout.stride, alignment: 16)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: count * TrackpadReader.Layout.stride)
        write(buffer, index: 0, state: 4, fingerID: 1, x: 0.25, y: 0.5, vx: 0.5, vy: -0.25)
        write(buffer, index: 1, state: 3, fingerID: 2, x: 0.75, y: 0.125, vx: 0, vy: 0)
        write(buffer, index: 2, state: 5, fingerID: 3, x: 1, y: 1, vx: 0, vy: 0)

        let touches = TrackpadReader.decodeTouches(UnsafeRawPointer(buffer), count: count)
        #expect(touches.count == 3)
        #expect(touches[0] == TouchPoint(state: 4, fingerID: 1, x: 0.25, y: 0.5, velocityX: 0.5, velocityY: -0.25))
        #expect(touches[1].x == 0.75 && touches[1].y == 0.125 && touches[1].fingerID == 2)
        #expect(touches.map(\.isDown) == [true, true, false])
        #expect(TrackpadReader.decodeTouches(UnsafeRawPointer(buffer), count: 0).isEmpty)
    }

    // MARK: Small pure helpers

    @Test func frameDifferencesIgnoreSubPixelNoise() {
        let before: [UInt32: CGRect] = [1: CGRect(x: 10, y: 20, width: 800, height: 600)]
        let same = AppHider.frameDifferences(before: before,
                                             after: [1: CGRect(x: 10.4, y: 19.6, width: 800, height: 600.5)], source: "cg")
        #expect(same.isEmpty)
    }

    @Test func frameDifferencesReportMovedResizedAndMissingWindows() {
        let before: [UInt32: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 800, height: 600),
            2: CGRect(x: 0, y: 0, width: 800, height: 600),
            3: CGRect(x: 0, y: 0, width: 800, height: 600),
        ]
        let after: [UInt32: CGRect] = [
            1: CGRect(x: 40, y: 0, width: 800, height: 600),
            2: CGRect(x: 0, y: 0, width: 640, height: 600),
        ]
        let differences = AppHider.frameDifferences(before: before, after: after, source: "ax")
        #expect(differences.map(\.windowID) == [1, 2, 3])
        #expect(differences.allSatisfy { $0.source == "ax" })
        #expect(differences[2].after == nil)
    }

    @Test func stageManagerStateIsReadFromPreferenceValues() {
        let on = StageManagerState.parse(["GloballyEnabled": NSNumber(value: 1), "AutoHide": NSNumber(value: 0),
                                          "Unrelated": "x"])
        #expect(on.enabled == true)
        #expect(on.isOn)
        #expect(on.summary == "ON")
        #expect(on.settings == ["AutoHide": "0"])

        let off = StageManagerState.parse(["GloballyEnabled": NSNumber(value: 0)])
        #expect(off.enabled == false)
        #expect(!off.isOn)
        #expect(off.summary == "off")

        let unset = StageManagerState.parse([:])
        #expect(unset.enabled == nil)
        #expect(!unset.isOn)
        #expect(unset.summary == "off (key not set)")
    }
}
