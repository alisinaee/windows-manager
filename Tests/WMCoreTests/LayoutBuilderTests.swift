import Foundation
import XCTest
@testable import WMCore

final class LayoutBuilderTests: XCTestCase {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: w, height: h)
    }

    private func totalArea(_ layout: Layout) -> Double {
        layout.zones.reduce(0) { $0 + $1.rect.width * $1.rect.height }
    }

    private func zone(_ layout: Layout, named name: String) -> Zone? {
        layout.zones.first { $0.name == name }
    }

    private func assertError(_ expected: LayoutBuilderError, _ body: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? LayoutBuilderError, expected, file: file, line: line)
        }
    }

    // MARK: Grids

    func testGrid2x2() throws {
        let layout = try LayoutBuilder.grid(rows: 2, columns: 2, name: "Grid")
        XCTAssertEqual(layout.name, "Grid")
        XCTAssertEqual(layout.zones.count, 4)
        XCTAssertEqual(totalArea(layout), 1, accuracy: 1e-9)
        XCTAssertEqual(layout.zones[0].rect, rect(0, 0, 0.5, 0.5))
        XCTAssertEqual(layout.zones[1].rect, rect(0.5, 0, 0.5, 0.5))
        XCTAssertEqual(layout.zones[2].rect, rect(0, 0.5, 0.5, 0.5))
        XCTAssertEqual(layout.zones[3].rect, rect(0.5, 0.5, 0.5, 0.5))
    }

    func testGrid3RowsBy2Columns() throws {
        // rows = 3, columns = 2: three rows of two cells.
        let layout = try LayoutBuilder.grid(rows: 3, columns: 2, name: "Tall")
        XCTAssertEqual(layout.zones.count, 6)
        XCTAssertEqual(totalArea(layout), 1, accuracy: 1e-9)
        let heights = Set(layout.zones.map { ($0.rect.height * 1000).rounded() })
        XCTAssertEqual(heights, [333])
        XCTAssertEqual(layout.zones.last!.rect.maxX, 1, accuracy: 1e-12)
        XCTAssertEqual(layout.zones.last!.rect.maxY, 1, accuracy: 1e-12)
    }

    func testGridRangeIsEnforced() {
        assertError(.gridOutOfRange) { _ = try LayoutBuilder.grid(rows: 0, columns: 2, name: "x") }
        assertError(.gridOutOfRange) { _ = try LayoutBuilder.grid(rows: 2, columns: 7, name: "x") }
        XCTAssertNoThrow(try LayoutBuilder.grid(rows: 6, columns: 1, name: "x"))
    }

    // MARK: Weights

    func testWeightedColumnsSumToOne() throws {
        let columns = try LayoutBuilder.weightedColumns([1, 2, 1])
        XCTAssertEqual(columns.count, 3)
        XCTAssertEqual(columns.reduce(0) { $0 + $1.rect.width }, 1, accuracy: 1e-12)
        XCTAssertEqual(columns[0].rect.width, 0.25, accuracy: 1e-12)
        XCTAssertEqual(columns[1].rect.x, 0.25, accuracy: 1e-12)
        XCTAssertEqual(columns[2].rect.maxX, 1, accuracy: 1e-12)
        XCTAssertTrue(columns.allSatisfy { $0.rect.height == 1 && $0.rect.y == 0 })
    }

    func testWeightedRowsSumToOne() throws {
        let rows = try LayoutBuilder.weightedRows([3, 1])
        XCTAssertEqual(rows.reduce(0) { $0 + $1.rect.height }, 1, accuracy: 1e-12)
        XCTAssertEqual(rows[0].rect.height, 0.75, accuracy: 1e-12)
        XCTAssertEqual(rows[1].rect.y, 0.75, accuracy: 1e-12)
        XCTAssertTrue(rows.allSatisfy { $0.rect.width == 1 && $0.rect.x == 0 })
    }

    func testWeightsRejectBadInput() {
        assertError(.invalidWeights) { _ = try LayoutBuilder.weightedColumns([]) }
        assertError(.invalidWeights) { _ = try LayoutBuilder.weightedRows([1, 0]) }
        assertError(.invalidWeights) { _ = try LayoutBuilder.weightedRows([1, -1]) }
        assertError(.invalidWeights) { _ = try LayoutBuilder.weightedRows([1, 100]) }  // 1% share is too thin
    }

    // MARK: Splits

    func testSplitVerticallyAndHorizontallyWrapLayoutSplit() throws {
        let base = LayoutPreset.halves.makeLayout()
        let leftID = base.zones[0].id
        let vertical = try LayoutBuilder.splitVertically(base, zoneID: leftID, fraction: 0.25)
        XCTAssertEqual(vertical.zones.count, 3)
        XCTAssertEqual(totalArea(vertical), 1, accuracy: 1e-9)
        XCTAssertEqual(vertical.zones[0].rect.width, 0.125, accuracy: 1e-12)

        let horizontal = try LayoutBuilder.splitHorizontally(base, zoneID: base.zones[1].id)
        XCTAssertEqual(horizontal.zones.count, 3)
        XCTAssertEqual(horizontal.zones[1].rect.height, 0.5, accuracy: 1e-12)
        XCTAssertEqual(base.zones.count, 2, "the input layout is not changed")
    }

    func testSplitRejectsBadFractionAndUnknownZone() {
        let base = LayoutPreset.halves.makeLayout()
        assertError(.invalidFraction) { _ = try LayoutBuilder.splitVertically(base, zoneID: base.zones[0].id, fraction: 0.95) }
        assertError(.zoneNotFound) { _ = try LayoutBuilder.splitVertically(base, zoneID: UUID(), fraction: 0.5) }
    }

    // MARK: Merge

    func testMergeAdjacentZonesIntoRectangle() throws {
        var layout = LayoutPreset.quarters.makeLayout()
        let topLeft = layout.zones[0].id
        let topRight = layout.zones[1].id
        layout.assign(bundleID: "com.a.one", to: topLeft)
        layout.assign(bundleID: "com.a.two", to: topRight)

        let merged = try LayoutBuilder.merge(layout, zoneIDs: [topRight, topLeft])
        XCTAssertEqual(merged.zones.count, 3)
        XCTAssertEqual(totalArea(merged), 1, accuracy: 1e-9)
        // The first zone in layout order keeps its id; the union is the top half.
        let top = merged.zones.first { $0.id == topLeft }
        XCTAssertEqual(top?.rect, rect(0, 0, 1, 0.5))
        XCTAssertEqual(Set(merged.apps(in: topLeft)), ["com.a.one", "com.a.two"])
        XCTAssertNil(merged.zones.first { $0.id == topRight })
    }

    func testMergeThreeZonesInARow() throws {
        let layout = try LayoutBuilder.grid(rows: 1, columns: 3, name: "Row")
        let merged = try LayoutBuilder.merge(layout, zoneIDs: layout.zones.map(\.id))
        XCTAssertEqual(merged.zones.count, 1)
        XCTAssertEqual(merged.zones[0].rect, rect(0, 0, 1, 1))
    }

    func testMergeRejectsNonAdjacentZones() throws {
        let layout = LayoutPreset.quarters.makeLayout()
        // Top-left and bottom-right only touch at a corner.
        assertError(.notAdjacent) { _ = try LayoutBuilder.merge(layout, zoneIDs: [layout.zones[0].id, layout.zones[3].id]) }
        // Left and right thirds with the middle one left out.
        let thirds = LayoutPreset.thirds.makeLayout()
        assertError(.notAdjacent) { _ = try LayoutBuilder.merge(thirds, zoneIDs: [thirds.zones[0].id, thirds.zones[2].id]) }
    }

    func testMergeRejectsLShape() throws {
        let layout = try LayoutBuilder.grid(rows: 2, columns: 2, name: "Grid")
        let lShape = [layout.zones[0].id, layout.zones[1].id, layout.zones[2].id]
        assertError(.notRectangular) { _ = try LayoutBuilder.merge(layout, zoneIDs: lShape) }
    }

    func testMergeArgumentErrors() {
        let layout = LayoutPreset.halves.makeLayout()
        assertError(.needsAtLeastTwoZones) { _ = try LayoutBuilder.merge(layout, zoneIDs: [layout.zones[0].id]) }
        assertError(.duplicateZone) { _ = try LayoutBuilder.merge(layout, zoneIDs: [layout.zones[0].id, layout.zones[0].id]) }
        assertError(.zoneNotFound) { _ = try LayoutBuilder.merge(layout, zoneIDs: [layout.zones[0].id, UUID()]) }
    }

    // MARK: Remove

    func testRemoveZoneGivesAreaToNeighbourAndKeepsApps() throws {
        var layout = LayoutPreset.halves.makeLayout()
        let left = layout.zones[0].id
        let right = layout.zones[1].id
        layout.assign(bundleID: "com.a.left", to: left)
        layout.assign(bundleID: "com.a.right", to: right)

        let result = try LayoutBuilder.removeZone(layout, zoneID: right)
        XCTAssertEqual(result.zones.count, 1)
        XCTAssertEqual(result.zones[0].id, left)
        XCTAssertEqual(result.zones[0].rect, rect(0, 0, 1, 1))
        XCTAssertEqual(Set(result.apps(in: left)), ["com.a.left", "com.a.right"])
        XCTAssertTrue(result.apps(in: right).isEmpty)
    }

    func testRemoveZonePicksLongestSharedEdge() throws {
        // Top row is one wide zone; the bottom row is split in two. Removing the wide top zone must go to the
        // bottom-left zone (it shares 0.6 of the edge) rather than the bottom-right one (0.4).
        let top = Zone(name: "Top", rect: rect(0, 0, 1, 0.5))
        let bottomLeft = Zone(name: "Bottom left", rect: rect(0, 0.5, 0.6, 0.5))
        let bottomRight = Zone(name: "Bottom right", rect: rect(0.6, 0.5, 0.4, 0.5))
        let layout = Layout(name: "T", zones: [top, bottomLeft, bottomRight])
        // Removing `top`: its longest shared edge is with bottom-left (0.6). Bottom-left plus the top row is an
        // L-shape, not a rectangle, so this throws instead of leaving a gap.
        assertError(.cannotAbsorb) { _ = try LayoutBuilder.removeZone(layout, zoneID: top.id) }

        // Removing bottom-right: its longest shared edge is with bottom-left (0.5, versus 0.4 with top). Their union
        // is the whole bottom row, so bottom-left grows to cover it.
        let result = try LayoutBuilder.removeZone(layout, zoneID: bottomRight.id)
        XCTAssertEqual(result.zones.first { $0.id == bottomLeft.id }?.rect, rect(0, 0.5, 1, 0.5))
        XCTAssertEqual(result.zones.first { $0.id == top.id }?.rect, rect(0, 0, 1, 0.5))
    }

    func testRemoveZoneWithoutNeighbourThrows() {
        let lone = Zone(name: "Only", rect: rect(0, 0, 1, 1))
        let layout = Layout(name: "One", zones: [lone])
        assertError(.noNeighbour) { _ = try LayoutBuilder.removeZone(layout, zoneID: lone.id) }
    }

    // MARK: Custom zones

    func testAddCustomZoneInFreeSpace() throws {
        let layout = Layout(name: "Custom", zones: [Zone(name: "Left", rect: rect(0, 0, 0.4, 1))])
        let result = try LayoutBuilder.addCustomZone(layout, rect: rect(0.5, 0.2, 0.3, 0.3), name: "Float")
        XCTAssertEqual(result.zones.count, 2)
        XCTAssertEqual(result.zones[1].name, "Float")
        XCTAssertEqual(result.zones[1].rect.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(result.zones[1].rect.y, 0.2, accuracy: 1e-12)
        XCTAssertEqual(result.zones[1].rect.width, 0.3, accuracy: 1e-12)
        XCTAssertEqual(result.zones[1].rect.height, 0.3, accuracy: 1e-12)
    }

    func testAddCustomZoneIsClippedToDisplay() throws {
        let layout = Layout(name: "Custom")
        let result = try LayoutBuilder.addCustomZone(layout, rect: rect(-0.5, 0.5, 1, 1))
        XCTAssertEqual(result.zones[0].rect, rect(0, 0.5, 0.5, 0.5))
    }

    func testAddCustomZoneRejectsOverlap() {
        let layout = LayoutPreset.halves.makeLayout()
        // Half of the new zone sits on the left zone.
        assertError(.overlapsExisting) { _ = try LayoutBuilder.addCustomZone(layout, rect: rect(0.4, 0, 0.2, 1)) }
    }

    func testAddCustomZoneAllowsTinyOverlap() throws {
        let layout = Layout(name: "Left only", zones: [Zone(name: "Left", rect: rect(0, 0, 0.5, 1))])
        // Overlap is 0.001 of a 0.501 wide zone, about 0.2%, under the 2% limit.
        XCTAssertNoThrow(try LayoutBuilder.addCustomZone(layout, rect: rect(0.499, 0, 0.501, 1)))
    }

    func testAddCustomZoneRejectsTooSmallOrOutside() {
        let layout = Layout(name: "Empty")
        assertError(.zoneTooSmall) { _ = try LayoutBuilder.addCustomZone(layout, rect: rect(0.1, 0.1, 0.02, 0.5)) }
        assertError(.zoneTooSmall) { _ = try LayoutBuilder.addCustomZone(layout, rect: rect(1.5, 0, 1, 1)) }
    }

    // MARK: Normalize

    func testNormalizeSnapsAndKeepsEdgesShared() {
        let a = Zone(name: "A", rect: rect(0, 0, 0.3333, 1))
        let b = Zone(name: "B", rect: rect(0.33334, 0, 0.66666, 1))
        var layout = Layout(name: "Snap", zones: [a, b])
        layout.assign(bundleID: "com.a.app", to: a.id)
        let result = LayoutBuilder.normalize(layout)
        XCTAssertEqual(result.zones[0].rect.maxX, result.zones[1].rect.x, accuracy: 1e-12)
        XCTAssertEqual(result.zones[0].rect.width, 0.333, accuracy: 1e-12)
        XCTAssertEqual(result.zones[1].rect.maxX, 1, accuracy: 1e-12)
        XCTAssertEqual(result.apps(in: a.id), ["com.a.app"])
    }

    func testNormalizeDropsSmallZonesAndTheirAssignments() {
        let big = Zone(name: "Big", rect: rect(0, 0, 0.97, 1))
        let sliver = Zone(name: "Sliver", rect: rect(0.97, 0, 0.02, 1))
        var layout = Layout(name: "Drop", zones: [big, sliver])
        layout.assign(bundleID: "com.a.gone", to: sliver.id)
        let result = LayoutBuilder.normalize(layout)
        XCTAssertEqual(result.zones.map(\.name), ["Big"])
        XCTAssertNil(result.assignments[sliver.id.uuidString])
        XCTAssertEqual(result.zones[0].rect.width, 0.97, accuracy: 1e-12)
    }
}
