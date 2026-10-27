import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite struct TileStackingTests {
    private func item(_ rect: CGRect, z: Int, app: String = "term", space: String = "s1", id: UUID = UUID()) -> TileStacking.Item {
        TileStacking.Item(windowID: id, spaceID: space, rect: rect, zIndex: z, appKey: app)
    }

    private let base = CGRect(x: 100, y: 100, width: 400, height: 300)

    @Test func nearlyIdenticalSameAppWindowsStack() {
        let ids = (0..<3).map { _ in UUID() }
        let items = [
            item(base, z: 0, id: ids[0]),
            item(base.offsetBy(dx: 10, dy: 8), z: 1, id: ids[1]),
            item(base.offsetBy(dx: -6, dy: 4), z: 2, id: ids[2]),
        ]
        let stacks = TileStacking.group(items)
        #expect(stacks.count == 1)
        #expect(stacks[0].members == ids)
        #expect(stacks[0].isStack)
    }

    @Test func sameAppThresholdIsIoUOfEightyPercent() {
        // 400x300 shifted right by x: IoU = (400 - x) / (400 + x).
        let nearly = base.offsetBy(dx: 40, dy: 0)    // 360/440 = 0.818
        let apart = base.offsetBy(dx: 60, dy: 0)     // 340/460 = 0.739
        #expect(TileStacking.group([item(base, z: 0), item(nearly, z: 1)]).count == 1)
        #expect(TileStacking.group([item(base, z: 0), item(apart, z: 1)]).count == 2)
    }

    @Test func smallWindowInsideBigOneIsNotStacked() {
        let inside = CGRect(x: 120, y: 120, width: 200, height: 150)
        #expect(TileStacking.group([item(base, z: 0), item(inside, z: 1)]).count == 2)
    }

    @Test func differentAppsStackOnlyWhenFramesAreIdentical() {
        let near = base.offsetBy(dx: 20, dy: 0)       // IoU 0.90: fine for one app, not for two
        #expect(TileStacking.group([item(base, z: 0, app: "a"), item(near, z: 1, app: "b")]).count == 2)
        #expect(TileStacking.group([item(base, z: 0, app: "a"), item(near, z: 1, app: "a")]).count == 1)
        #expect(TileStacking.group([item(base, z: 0, app: "a"), item(base, z: 1, app: "b")]).count == 1)
    }

    @Test func differentSpacesNeverStack() {
        let stacks = TileStacking.group([item(base, z: 0, space: "s1"), item(base, z: 1, space: "s2")])
        #expect(stacks.count == 2)
    }

    @Test func orderIsFrontFirstAndStable() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        // Input order is scrambled; z decides. c and d tie and keep input order.
        let far = CGRect(x: 900, y: 600, width: 100, height: 100)
        let items = [
            item(base, z: 2, id: a),
            item(far, z: 0, app: "other", id: d),
            item(base, z: 1, id: b),
            item(base, z: 1, id: c),
        ]
        let first = TileStacking.group(items)
        #expect(first.map(\.members) == [[d], [b, c, a]])
        #expect(TileStacking.group(items) == first)
        #expect(first[1].id == TileStacking.group(items.reversed().map { $0 }).first { $0.isStack }?.id)
    }

    @Test func doesNotChainThroughMembers() {
        // Each step is IoU ~0.82 with the previous one, but the third is far from the front window.
        let w0 = base
        let w1 = base.offsetBy(dx: 38, dy: 0)
        let w2 = base.offsetBy(dx: 76, dy: 0)
        let stacks = TileStacking.group([item(w0, z: 0), item(w1, z: 1), item(w2, z: 2)])
        #expect(stacks.map(\.count) == [2, 1])
    }

    @Test func emptyFramesAreHandled() {
        let empty = CGRect(x: 10, y: 10, width: 0, height: 0)
        #expect(TileStacking.iou(empty, empty) == 0)
        #expect(TileStacking.group([item(empty, z: 0), item(empty, z: 1)]).count == 2)
        #expect(TileStacking.group([]).isEmpty)
    }
}
