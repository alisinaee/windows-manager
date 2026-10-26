import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// PM7: map snapping. Covers the acceptance cases in docs/PLAN-profile-maps.md (section E, PM7).
/// A monitor content rect with a negative origin, like a monitor left of the main one.
private let content = CGRect(x: 100, y: -1000, width: 1000, height: 800)

@Suite struct MapSnappingTests {

    static func assertRect(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.0001,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(a.minX - b.minX) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(a.minY - b.minY) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(a.width - b.width) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(a.height - b.height) < tolerance, sourceLocation: sourceLocation)
    }

    @Test func pointInsideZoneSnapsToZoneRect() {
        let left = CGRect(x: 100, y: -1000, width: 500, height: 800)
        let right = CGRect(x: 600, y: -1000, width: 500, height: 800)
        // Center (330, -700) is inside the left zone; the rect itself is not aligned with it.
        let dragged = CGRect(x: 200, y: -800, width: 260, height: 200)
        let result = MapSnapping.snap(rect: dragged, in: content,
                                      zones: [(name: "Left half", rect: left), (name: "Right half", rect: right)],
                                      edges: [])
        #expect(result.zoneName == "Left half")
        Self.assertRect(result.rect, left)
        #expect(result.snappedEdges.isEmpty)
    }

    @Test func smallestZoneWinsWhenCenterIsInTwo() {
        let big = CGRect(x: 100, y: -1000, width: 1000, height: 800)
        let quarter = CGRect(x: 100, y: -1000, width: 500, height: 400)
        let dragged = CGRect(x: 150, y: -950, width: 200, height: 200)
        let result = MapSnapping.snap(rect: dragged, in: content,
                                      zones: [(name: "Full", rect: big), (name: "Quarter", rect: quarter)],
                                      edges: [])
        #expect(result.zoneName == "Quarter")
        Self.assertRect(result.rect, quarter)
    }

    @Test func optionDisablesZoneAndEdgeSnapping() {
        let left = CGRect(x: 100, y: -1000, width: 500, height: 800)
        let dragged = CGRect(x: 203, y: -700, width: 260, height: 200)
        let disabled = MapSnapping.SnapOptions(disabled: true)
        let result = MapSnapping.snap(rect: dragged, in: content, zones: [(name: "Left", rect: left)],
                                      edges: [CGRect(x: 600, y: -300, width: 200, height: 200)], option: disabled)
        #expect(result.zoneName == nil)
        #expect(result.snappedEdges.isEmpty)
        Self.assertRect(result.rect, dragged)
    }

    @Test func optionStillClampsInsideMonitor() {
        let dragged = CGRect(x: 1500, y: -1500, width: 260, height: 200)
        let result = MapSnapping.snap(rect: dragged, in: content, zones: [], edges: [],
                                      option: MapSnapping.SnapOptions(disabled: true))
        #expect(content.contains(result.rect))
    }

    @Test func edgeSnapWithinThresholdMovesToMonitorEdge() {
        // Left edge 5 pt from the monitor's left edge: snaps to it. Top is far from any edge.
        let dragged = CGRect(x: content.minX + 5, y: -700, width: 260, height: 200)
        let result = MapSnapping.snap(rect: dragged, in: content, zones: [], edges: [])
        #expect(result.snappedEdges == [.left])
        #expect(abs(result.rect.minX - content.minX) < 0.0001)
        #expect(abs(result.rect.minY - dragged.minY) < 0.0001)
        #expect(result.rect.width == dragged.width)
    }

    @Test func edgeSnapOutsideThresholdDoesNotMove() {
        let dragged = CGRect(x: content.minX + 9, y: -700, width: 260, height: 200)
        let result = MapSnapping.snap(rect: dragged, in: content, zones: [], edges: [])
        #expect(result.snappedEdges.isEmpty)
        Self.assertRect(result.rect, dragged)
    }

    @Test func edgeSnapAlignsWithOtherWindowEdge() {
        let other = CGRect(x: 500, y: -500, width: 300, height: 200)   // maxX = 800
        // Right edge at 795, 5 pt from other.maxX: snaps to 800. Its y edges already line up with `other`.
        let dragged = CGRect(x: 535, y: -500, width: 260, height: 200)
        let result = MapSnapping.snap(rect: dragged, in: content, zones: [], edges: [other])
        #expect(result.snappedEdges.contains(.right))
        #expect(abs(result.rect.maxX - 800) < 0.0001)
        #expect(abs(result.rect.minY - (-500)) < 0.0001)
    }

    @Test func edgeSnapToOtherWindowOutsideThresholdKeepsPosition() {
        let other = CGRect(x: 500, y: -500, width: 300, height: 200)
        // 20 pt away from every line on both axes, and inside the monitor.
        let far = CGRect(x: 520, y: -460, width: 100, height: 100)
        let result = MapSnapping.snap(rect: far, in: content, zones: [], edges: [other])
        #expect(result.snappedEdges.isEmpty)
        Self.assertRect(result.rect, far)
    }

    @Test func snapRespectsCustomThreshold() {
        let dragged = CGRect(x: content.minX + 12, y: -700, width: 260, height: 200)
        let wide = MapSnapping.snap(rect: dragged, in: content, zones: [], edges: [],
                                    option: MapSnapping.SnapOptions(threshold: 20))
        #expect(wide.snappedEdges == [.left])
        let narrow = MapSnapping.snap(rect: dragged, in: content, zones: [], edges: [],
                                      option: MapSnapping.SnapOptions(threshold: 4))
        #expect(narrow.snappedEdges.isEmpty)
    }

    @Test func tinyRectIsRaisedToMinimumSize() {
        let tiny = CGRect(x: 300, y: -600, width: 10, height: 10)
        let result = MapSnapping.snap(rect: tiny, in: content, zones: [], edges: [])
        #expect(result.rect.width == MapSnapping.minimumWidth)
        #expect(result.rect.height == MapSnapping.minimumHeight)
    }

    @Test func snappedResultStaysInsideMonitor() {
        // Dragged against the top-right corner, with a neighbour that pushes it out after snapping.
        let other = CGRect(x: 1080, y: -300, width: 100, height: 100)
        let dragged = CGRect(x: 880, y: -240, width: 260, height: 200)
        let result = MapSnapping.snap(rect: dragged, in: content, zones: [], edges: [other])
        #expect(content.contains(result.rect))
    }

    @Test func defaultPlacementIsCenteredHalfByThreeQuarters() {
        let rect = MapSnapping.defaultPlacement(for: content, index: 0)
        #expect(abs(rect.width - 500) < 0.0001)
        #expect(abs(rect.height - 560) < 0.0001)
        #expect(abs(rect.midX - content.midX) < 0.0001)
        #expect(abs(rect.midY - content.midY) < 0.0001)
    }

    @Test func defaultPlacementCascadesByOffset() {
        let first = MapSnapping.defaultPlacement(for: content, index: 0)
        let second = MapSnapping.defaultPlacement(for: content, index: 1)
        let third = MapSnapping.defaultPlacement(for: content, index: 2)
        #expect(abs(second.minX - first.minX - MapSnapping.cascadeOffset) < 0.0001)
        #expect(abs(second.minY - first.minY - MapSnapping.cascadeOffset) < 0.0001)
        #expect(abs(third.minX - second.minX - MapSnapping.cascadeOffset) < 0.0001)
    }

    @Test func defaultPlacementWrapsAndStaysInside() {
        // 800 pt tall content: room is 800 - 560 = 240, so 11 steps (0...10), then the cascade wraps.
        for index in 0..<40 {
            let rect = MapSnapping.defaultPlacement(for: content, index: index)
            #expect(content.contains(rect), "index \(index)")
        }
        let zero = MapSnapping.defaultPlacement(for: content, index: 0)
        let wrapped = MapSnapping.defaultPlacement(for: content, index: 11)
        Self.assertRect(zero, wrapped)
    }

    @Test func defaultPlacementClampsOnSmallMonitor() {
        let small = CGRect(x: -500, y: 0, width: 120, height: 90)
        for index in 0..<5 {
            let rect = MapSnapping.defaultPlacement(for: small, index: index)
            #expect(small.contains(rect), "index \(index)")
        }
    }

    @Test func relativeFrameRoundTrip() {
        let rects = [
            CGRect(x: 100, y: -1000, width: 1000, height: 800),
            CGRect(x: 250.5, y: -612.25, width: 333.75, height: 180.5),
            CGRect(x: 1000, y: -200, width: 0.5, height: 0.25),
        ]
        for rect in rects {
            let relative = MapSnapping.relativeFrame(of: rect, in: content)
            Self.assertRect(MapSnapping.canvasRect(forRelative: relative, in: content), rect)
        }
    }

    @Test func relativeFrameIsFractionsOfMonitorContent() {
        let rect = CGRect(x: 350, y: -800, width: 500, height: 400)
        let relative = MapSnapping.relativeFrame(of: rect, in: content)
        Self.assertRect(relative, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        // The full content maps to 0, 0, 1, 1.
        Self.assertRect(MapSnapping.relativeFrame(of: content, in: content),
                        CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func relativeFrameOfDegenerateContentIsFullFrame() {
        let empty = CGRect(x: 0, y: 0, width: 0, height: 0)
        Self.assertRect(MapSnapping.relativeFrame(of: CGRect(x: 5, y: 5, width: 5, height: 5), in: empty),
                        CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
