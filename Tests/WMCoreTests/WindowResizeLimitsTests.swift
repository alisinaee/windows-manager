import CoreGraphics
import XCTest
@testable import WMCore

final class WindowResizeLimitsTests: XCTestCase {
    func testUnsettableSizeFixesBothAxes() {
        let l = WindowResizeLimits.fromAttributes(sizeSettable: false, positionSettable: true)
        XCTAssertTrue(l.fixedWidth && l.fixedHeight && l.canMove)
        let free = WindowResizeLimits.fromAttributes(sizeSettable: true, positionSettable: false)
        XCTAssertFalse(free.fixedWidth || free.fixedHeight)
        XCTAssertFalse(free.canMove)
    }

    func testProbeDecisions() {
        let fixed = WindowResizeLimits.fromProbe(width: .init(original: 400, afterGrow: 400, afterShrink: 400),
                                                 height: .init(original: 300, afterGrow: 308, afterShrink: 292))
        XCTAssertTrue(fixed.fixedWidth); XCTAssertFalse(fixed.fixedHeight)
        let atMax = WindowResizeLimits.fromProbe(width: .init(original: 500, afterGrow: 500, afterShrink: 492),
                                                 height: .init(original: 300, afterGrow: 308, afterShrink: 300))
        XCTAssertEqual(atMax.maxSize?.width, 500)
        XCTAssertEqual(atMax.minSize?.height, 300)
        XCTAssertFalse(atMax.fixedWidth)
    }

    func testClampKeepsFixedWidth() {
        let l = WindowResizeLimits(fixedWidth: true)
        let current = CGRect(x: 100, y: 100, width: 400, height: 300)
        let out = l.clamp(CGRect(x: 100, y: 100, width: 600, height: 500), current: current)
        XCTAssertEqual(out, CGRect(x: 100, y: 100, width: 400, height: 500))
        // Left-edge resize keeps the right edge.
        let left = l.clamp(CGRect(x: 50, y: 100, width: 450, height: 300), current: current)
        XCTAssertEqual(left.maxX, 500); XCTAssertEqual(left.width, 400)
        // A pure move is untouched.
        let moved = CGRect(x: 200, y: 150, width: 400, height: 300)
        XCTAssertEqual(l.clamp(moved, current: current), moved)
    }

    func testClampMinMax() {
        let l = WindowResizeLimits(minSize: CGSize(width: 300, height: 0), maxSize: CGSize(width: 500, height: 400))
        let out = l.clamp(CGRect(x: 0, y: 0, width: 900, height: 100), current: CGRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertEqual(out.width, 500); XCTAssertEqual(out.height, 100)
        XCTAssertEqual(l.clamp(CGRect(x: 0, y: 0, width: 100, height: 50), current: CGRect(x: 0, y: 0, width: 400, height: 200)).width, 300)
    }

    func testBackwardCompatibleDecode() throws {
        let l = try JSONDecoder().decode(WindowResizeLimits.self, from: Data("{}".utf8))
        XCTAssertFalse(l.hasRestrictions)
        let rt = WindowResizeLimits(fixedWidth: true, minSize: CGSize(width: 10, height: 20))
        let back = try JSONDecoder().decode(WindowResizeLimits.self, from: JSONEncoder().encode(rt))
        XCTAssertEqual(rt, back)
    }
}
