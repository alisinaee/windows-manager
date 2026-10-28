import CoreGraphics
import XCTest
@testable import WMCore

final class AutoLayoutLinkedTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private func items(_ ids: [String?]) -> [AutoLayout.Item] { ids.map { AutoLayout.Item(id: UUID(), bundleID: $0) } }

    func testCountsProduceNonOverlappingTilesInside() {
        for n in 1...7 {
            let its = items(Array(repeating: nil, count: n))
            for c in AutoLayout.candidates(items: its, visible: screen, gap: 8) {
                XCTAssertEqual(c.frames.count, n, "\(n) \(c.name)")
                let rects = Array(c.frames.values)
                for (i, a) in rects.enumerated() {
                    XCTAssertTrue(screen.insetBy(dx: -0.01, dy: -0.01).contains(a), "\(n) \(c.name)")
                    for b in rects[(i + 1)...] { XCTAssertFalse(OverlapLock.overlaps(a, b), "\(n) \(c.name)") }
                }
            }
        }
    }

    func testOneIsFullAndFourIsQuadrants() {
        let one = AutoLayout.candidates(items: items([nil]), visible: screen)
        XCTAssertEqual(one.first?.frames.values.first, screen)
        let four = AutoLayout.candidates(items: items([nil, nil, nil, nil]), visible: screen, gap: 0)
        XCTAssertEqual(four.first?.name, "Quadrants")
        XCTAssertTrue(four.first!.frames.values.allSatisfy { $0.width == 600 && $0.height == 400 })
    }

    func testTwoMainPlusUtilityPrefersTwoThirds() {
        let its = items(["com.tinyspeck.slackmacgap", "com.apple.dt.Xcode"])
        let c = AutoLayout.candidates(items: its, visible: screen, gap: 0)
        XCTAssertEqual(c[0].name, "Main 2/3 + side 1/3")
        XCTAssertEqual(c[0].frames[its[1].id]?.width ?? 0, 800, accuracy: 0.01)   // main gets the big part
        XCTAssertEqual(AutoLayout.candidates(items: items([nil, nil]), visible: screen)[0].name, "Halves")
    }

    func testThreeMainLeft() {
        let its = items([nil, "com.google.Chrome", nil])
        let c = AutoLayout.candidates(items: its, visible: screen, gap: 0)[0]
        XCTAssertEqual(c.frames[its[1].id]?.height, 800)
        XCTAssertEqual(c.frames[its[0].id]?.minX ?? 0, c.frames[its[2].id]?.minX ?? -1, accuracy: 0.01)
    }

    func testSharedEdgeAndLinkedResize() {
        let a = CGRect(x: 0, y: 0, width: 500, height: 800), b = CGRect(x: 501, y: 0, width: 699, height: 800)
        let id = UUID()
        let ns = [LinkedResize.Neighbour(id: id, rect: b)]
        XCTAssertEqual(LinkedResize.sharedEdge(of: a, side: .right, among: ns).count, 1)
        XCTAssertTrue(LinkedResize.sharedEdge(of: a, side: .left, among: ns).isEmpty)
        let r = LinkedResize.apply(start: a, proposed: CGRect(x: 0, y: 0, width: 600, height: 800), handle: .right,
                                   neighbours: ns, minSize: CGSize(width: 80, height: 60))
        XCTAssertEqual(r.neighbours[id], CGRect(x: 600, y: 0, width: 600, height: 800))
        // Neighbour keeps its minimum width.
        let big = LinkedResize.apply(start: a, proposed: CGRect(x: 0, y: 0, width: 1190, height: 800), handle: .right,
                                     neighbours: ns, minSize: CGSize(width: 80, height: 60))
        XCTAssertEqual(big.rect.maxX, 1120, accuracy: 0.01)
        XCTAssertEqual(big.neighbours[id]?.width ?? 0, 80, accuracy: 0.01)
    }

    func testClampMoveKeepsInsideAndOutOfOthers() {
        let other = CGRect(x: 0, y: 0, width: 500, height: 800)
        let moved = CGRect(x: 400, y: 100, width: 300, height: 200)
        let r = OverlapLock.constrainMove(moved, monitor: screen, others: [other], fallback: moved)
        XCTAssertFalse(OverlapLock.overlaps(r, other))
        XCTAssertTrue(screen.contains(r))
        let out = OverlapLock.constrainMove(CGRect(x: 1100, y: 700, width: 300, height: 200), monitor: screen, others: [], fallback: .zero)
        XCTAssertEqual(out, CGRect(x: 900, y: 600, width: 300, height: 200))
    }

    func testConstrainResizeStopsAtNeighbour() {
        let start = CGRect(x: 0, y: 0, width: 400, height: 800)
        let other = CGRect(x: 600, y: 0, width: 600, height: 800)
        let grown = CGRect(x: 0, y: 0, width: 900, height: 800)
        let r = OverlapLock.constrainResize(grown, start: start, handle: .right, monitor: screen, others: [other],
                                            minSize: CGSize(width: 80, height: 60))
        XCTAssertEqual(r.maxX, 600, accuracy: 0.01)
    }
}
