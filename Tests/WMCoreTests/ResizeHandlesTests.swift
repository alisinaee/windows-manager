import CoreGraphics
import XCTest
@testable import WMCore

final class ResizeHandlesTests: XCTestCase {
    private let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
    private let minSize = CGSize(width: 80, height: 60)

    func testHandlePositions() {
        XCTAssertEqual(ResizeHandles.center(of: .topLeft, in: rect), CGPoint(x: 100, y: 100))
        XCTAssertEqual(ResizeHandles.center(of: .right, in: rect), CGPoint(x: 300, y: 150))
        XCTAssertEqual(ResizeHandles.center(of: .bottom, in: rect), CGPoint(x: 200, y: 200))
        XCTAssertEqual(ResizeHandles.handleRect(.bottomRight, in: rect, size: 10), CGRect(x: 295, y: 195, width: 10, height: 10))
    }

    func testHitTestCornersAndEdges() {
        XCTAssertEqual(ResizeHandles.hitTest(CGPoint(x: 102, y: 98), in: rect), .topLeft)
        XCTAssertEqual(ResizeHandles.hitTest(CGPoint(x: 200, y: 101), in: rect), .top)
        XCTAssertEqual(ResizeHandles.hitTest(CGPoint(x: 299, y: 150), in: rect), .right)
        XCTAssertNil(ResizeHandles.hitTest(CGPoint(x: 200, y: 150), in: rect))
        XCTAssertNil(ResizeHandles.hitTest(CGPoint(x: 120, y: 100), in: rect))
    }

    func testHitTestSmallRectStillReachesCorner() {
        let tiny = CGRect(x: 0, y: 0, width: 12, height: 12)
        XCTAssertEqual(ResizeHandles.hitTest(CGPoint(x: 1, y: 1), in: tiny), .topLeft)
        XCTAssertEqual(ResizeHandles.hitTest(CGPoint(x: 11, y: 11), in: tiny), .bottomRight)
    }

    func testResizeRightEdgeAndCorner() {
        XCTAssertEqual(ResizeHandles.resize(rect, handle: .right, by: CGSize(width: 40, height: 99), minSize: minSize),
                       CGRect(x: 100, y: 100, width: 240, height: 100))
        XCTAssertEqual(ResizeHandles.resize(rect, handle: .topLeft, by: CGSize(width: 20, height: 10), minSize: minSize),
                       CGRect(x: 120, y: 110, width: 180, height: 90))
    }

    func testResizeKeepsMinimumAndFixedEdge() {
        let r = ResizeHandles.resize(rect, handle: .left, by: CGSize(width: 500, height: 0), minSize: minSize)
        XCTAssertEqual(r.maxX, 300)
        XCTAssertEqual(r.width, 80)
        let b = ResizeHandles.resize(rect, handle: .bottom, by: CGSize(width: 0, height: -500), minSize: minSize)
        XCTAssertEqual(b.minY, 100)
        XCTAssertEqual(b.height, 60)
    }

    func testResizeStaysInBounds() {
        let bounds = CGRect(x: 90, y: 90, width: 250, height: 150)
        let r = ResizeHandles.resize(rect, handle: .bottomRight, by: CGSize(width: 500, height: 500), minSize: minSize, within: bounds)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 240, height: 140))
        let l = ResizeHandles.resize(rect, handle: .topLeft, by: CGSize(width: -500, height: -500), minSize: minSize, within: bounds)
        XCTAssertEqual(l.minX, 90)
        XCTAssertEqual(l.minY, 90)
        XCTAssertEqual(l.maxX, 300)
    }

    func testSnapMovingEdgesOnly() {
        let dragged = CGRect(x: 100, y: 100, width: 203, height: 100)
        let snapped = ResizeHandles.snapMovingEdges(dragged, handle: .right, xLines: [300, 98], yLines: [102],
                                                    threshold: 8, minSize: minSize)
        XCTAssertEqual(snapped, CGRect(x: 100, y: 100, width: 200, height: 100))   // left and y did not move
    }

    func testSnapRespectsThresholdAndMinimum() {
        let dragged = CGRect(x: 100, y: 100, width: 150, height: 100)
        XCTAssertEqual(ResizeHandles.snapMovingEdges(dragged, handle: .right, xLines: [300], yLines: [],
                                                     threshold: 8, minSize: minSize), dragged)
        let tight = CGRect(x: 100, y: 100, width: 85, height: 100)
        XCTAssertEqual(ResizeHandles.snapMovingEdges(tight, handle: .right, xLines: [170], yLines: [],
                                                     threshold: 20, minSize: minSize).width, 80)
    }

    func testNudgeClampsInsideUnitSquare() {
        let r = CGRect(x: 0.02, y: 0.5, width: 0.5, height: 0.5)
        XCTAssertEqual(ResizeHandles.nudge(relative: r, dx: -0.05, dy: 0.05), CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        let n = ResizeHandles.nudge(relative: r, dx: 0.01, dy: -0.01)
        XCTAssertEqual(n.minX, 0.03, accuracy: 1e-9)
        XCTAssertEqual(n.minY, 0.49, accuracy: 1e-9)
    }

    func testRelativeResizeKeepsOriginAndLimits() {
        let r = CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4)
        let grown = ResizeHandles.resize(relative: r, dw: 0.3, dh: -0.5, minSize: CGSize(width: 0.1, height: 0.1))
        XCTAssertEqual(grown.minX, 0.5)
        XCTAssertEqual(grown.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(grown.height, 0.1, accuracy: 1e-9)
    }
}
