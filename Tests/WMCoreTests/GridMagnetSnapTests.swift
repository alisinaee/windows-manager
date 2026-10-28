import CoreGraphics
import Testing
@testable import WMCore

@Suite struct GridMagnetSnapTests {
    let content = CGRect(x: 100, y: 50, width: 1200, height: 600)

    @Test func specClampsAndNamesPresets() {
        #expect(GridSpec(columns: 0, rows: 999) == GridSpec(columns: 1, rows: 64))
        #expect(GridSpec.medium.presetName == "Medium")
        #expect(GridSpec(columns: 5, rows: 5).presetName == "Custom")
    }

    @Test func gridLines() {
        let xs = GridSnap.xLines(GridSpec(columns: 4, rows: 2), in: content)
        #expect(xs == [100, 400, 700, 1000, 1300])
        #expect(GridSnap.yLines(GridSpec(columns: 4, rows: 2), in: content) == [50, 350, 650])
    }

    @Test func moveSnapsNearestEdgeToGrid() {
        let spec = GridSpec(columns: 4, rows: 2)
        let out = GridSnap.snapMove(CGRect(x: 380, y: 60, width: 200, height: 100), spec: spec, in: content)
        #expect(out.minX == 400 && out.minY == 50 && out.size == CGSize(width: 200, height: 100))
        // Right edge closer than left edge.
        let r = GridSnap.snapMove(CGRect(x: 505, y: 60, width: 200, height: 100), spec: spec, in: content)
        #expect(r.maxX == 700)
    }

    @Test func resizeSnapsOnlyMovingEdges() {
        let spec = GridSpec(columns: 4, rows: 2)
        let out = GridSnap.snapResize(CGRect(x: 400, y: 50, width: 310, height: 290), handle: .bottomRight, spec: spec,
                                      in: content, minSize: CGSize(width: 80, height: 60))
        #expect(out == CGRect(x: 400, y: 50, width: 300, height: 300))
    }

    @Test func magnetMoveSticksToOtherTileAndReportsGuide() {
        let other = CGRect(x: 500, y: 100, width: 200, height: 200)
        let r = MagnetSnap.snapMove(CGRect(x: 705, y: 400, width: 150, height: 100), monitor: content, others: [other], threshold: 8)
        #expect(r.rect.minX == 700)
        #expect(r.guides == [MagnetSnap.Guide(axis: .vertical, position: 700)])
    }

    @Test func magnetMoveSticksToMonitorEdgeAndIgnoresFar() {
        let r = MagnetSnap.snapMove(CGRect(x: 104, y: 300, width: 150, height: 100), monitor: content, others: [], threshold: 8)
        #expect(r.rect.minX == 100)
        let far = MagnetSnap.snapMove(CGRect(x: 120, y: 300, width: 150, height: 100), monitor: content, others: [], threshold: 8)
        #expect(far.rect.minX == 120 && far.guides.isEmpty)
    }

    @Test func magnetResizeSnapsMovingEdgeOnly() {
        let other = CGRect(x: 800, y: 100, width: 100, height: 100)
        let r = MagnetSnap.snapResize(CGRect(x: 300, y: 300, width: 495, height: 100), handle: .right, monitor: content,
                                      others: [other], threshold: 8, minSize: CGSize(width: 80, height: 60))
        #expect(r.rect == CGRect(x: 300, y: 300, width: 500, height: 100))
        #expect(r.guides == [MagnetSnap.Guide(axis: .vertical, position: 800)])
    }

    @Test func thresholdScalesWithZoom() {
        #expect(MagnetSnap.canvasThreshold(zoom: 0.5) == 16)
    }
}
