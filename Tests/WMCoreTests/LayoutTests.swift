import CoreGraphics
import Foundation
import XCTest
@testable import WMCore

final class LayoutTests: XCTestCase {
    func testPresetsCoverDisplayWithoutOverlap() {
        for preset in LayoutPreset.allCases where preset != .center {
            let zones = preset.makeZones()
            let area = zones.reduce(0.0) { $0 + $1.rect.width * $1.rect.height }
            XCTAssertEqual(area, 1.0, accuracy: 1e-9, preset.title)
        }
        XCTAssertEqual(LayoutPreset.quarters.makeZones().count, 4)
        XCTAssertEqual(LayoutPreset.thirds.makeZones().count, 3)
        XCTAssertEqual(LayoutPreset.center.makeZones().count, 1)
    }

    func testFrameWithGap() {
        let display = CGRect(x: 100, y: 50, width: 1000, height: 600)
        let left = LayoutGeometry.frame(of: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1), in: display, gap: 10)
        XCTAssertEqual(left, CGRect(x: 110, y: 60, width: 485, height: 580))
        let right = LayoutGeometry.frame(of: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1), in: display, gap: 10)
        XCTAssertEqual(right.minX - left.maxX, 10, accuracy: 1e-9)
        XCTAssertEqual(right.maxX, 1090, accuracy: 1e-9)
        let none = LayoutGeometry.frame(of: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), in: display)
        XCTAssertEqual(none, CGRect(x: 350, y: 200, width: 500, height: 300))
    }

    func testHitTesting() {
        let layout = LayoutPreset.quarters.makeLayout()
        XCTAssertEqual(layout.zone(atX: 0.1, y: 0.1)?.name, "Top left")
        XCTAssertEqual(layout.zone(atX: 0.9, y: 0.9)?.name, "Bottom right")
        XCTAssertEqual(layout.zone(atX: 0.5, y: 0.5)?.name, "Bottom right")
        XCTAssertNil(layout.zone(atX: 1.0, y: 0.5))
        let frame = CGRect(x: 1000, y: 0, width: 200, height: 100)
        XCTAssertEqual(layout.zone(at: CGPoint(x: 1150, y: 20), in: frame)?.name, "Top right")
        XCTAssertNil(layout.zone(at: CGPoint(x: 10, y: 20), in: frame))
    }

    func testSplit() {
        var layout = Layout(name: "L", zones: [Zone(name: "Full", rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1))])
        let original = layout.zones[0].id
        layout.assign(bundleID: "com.a", to: original)
        let ids = layout.split(zoneID: original, axis: .vertical, fraction: 0.25)
        XCTAssertNotNil(ids)
        XCTAssertEqual(layout.zones.count, 2)
        XCTAssertEqual(layout.zones[0].rect.width, 0.25, accuracy: 1e-9)
        XCTAssertEqual(layout.zones[1].rect.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(layout.apps(in: ids!.0), ["com.a"])
        XCTAssertNil(layout.split(zoneID: UUID(), axis: .horizontal))
        // Too small to split.
        var tiny = Layout(name: "T", zones: [Zone(name: "t", rect: NormalizedRect(x: 0, y: 0, width: 0.08, height: 1))])
        XCTAssertNil(tiny.split(zoneID: tiny.zones[0].id, axis: .vertical))
    }

    func testAssignMovesAppBetweenZones() {
        var layout = LayoutPreset.halves.makeLayout()
        let a = layout.zones[0].id, b = layout.zones[1].id
        layout.assign(bundleID: "x", to: a)
        layout.assign(bundleID: "x", to: b)
        XCTAssertEqual(layout.apps(in: a), [])
        XCTAssertEqual(layout.apps(in: b), ["x"])
        layout.assign(bundleID: "y", to: UUID())
        XCTAssertNil(layout.assignments.values.first { $0.contains("y") })
        layout.removeZone(b)
        XCTAssertTrue(layout.assignments.isEmpty)
    }

    func testMoveSharedEdgeResizesBothZones() {
        var layout = LayoutPreset.halves.makeLayout()
        layout.moveEdge(of: layout.zones[0].id, edge: .right, to: 0.7)
        XCTAssertEqual(layout.zones[0].rect.width, 0.7, accuracy: 1e-9)
        XCTAssertEqual(layout.zones[1].rect.x, 0.7, accuracy: 1e-9)
        XCTAssertEqual(layout.zones[1].rect.width, 0.3, accuracy: 1e-9)
        layout.moveEdge(of: layout.zones[1].id, edge: .left, to: 0.0)
        XCTAssertEqual(layout.zones[0].rect.width, Layout.minZoneSize, accuracy: 1e-9)
        XCTAssertEqual(layout.zones[1].rect.x, Layout.minZoneSize, accuracy: 1e-9)
    }

    func testMoveEdgeInQuartersMovesBothRows() {
        var layout = LayoutPreset.quarters.makeLayout()
        layout.moveEdge(of: layout.zones[0].id, edge: .bottom, to: 0.3)
        XCTAssertEqual(layout.zones[0].rect.height, 0.3, accuracy: 1e-9)
        XCTAssertEqual(layout.zones[1].rect.height, 0.3, accuracy: 1e-9)
        XCTAssertEqual(layout.zones[2].rect.y, 0.3, accuracy: 1e-9)
        XCTAssertEqual(layout.zones[3].rect.height, 0.7, accuracy: 1e-9)
    }

    func testMatchesDisplay() {
        let d = DisplayIdentity(uuid: "abc", name: "X", frame: .zero, visibleFrame: .zero, isMain: true, isBuiltIn: true)
        XCTAssertTrue(Layout(name: "a").matches(display: d))
        XCTAssertTrue(Layout(name: "a", displayKey: "ABC").matches(display: d))
        XCTAssertFalse(Layout(name: "a", displayKey: "other").matches(display: d))
    }

    func testStoreRoundTripAndErrors() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("layouts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(folder: dir)
        XCTAssertEqual(try store.load(), [])
        var layout = LayoutPreset.thirds.makeLayout(displayKey: "uuid-1")
        layout.assign(bundleID: "com.app", to: layout.zones[1].id)
        try store.upsert(layout)
        try store.upsert(LayoutPreset.halves.makeLayout())
        XCTAssertEqual(try LayoutStore(folder: dir).load().count, 2)
        XCTAssertEqual(try store.load().first, layout)
        layout.name = "Renamed"
        try store.upsert(layout)
        XCTAssertEqual(try store.load().count, 2)
        XCTAssertEqual(try store.load().first?.name, "Renamed")
        try store.delete(id: layout.id)
        XCTAssertEqual(try store.load().count, 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftovers, ["layouts.json"])

        try Data("nope".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        try Data(#"{"schema":99,"layouts":[]}"#.utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? LayoutStoreError, .unsupportedSchema(found: 99, supported: 1)) }
    }
}
