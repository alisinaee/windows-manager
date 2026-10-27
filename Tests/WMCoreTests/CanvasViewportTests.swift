import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite struct CanvasViewportTests {
    @Test func zoomKeepsAnchorFixed() {
        let start = CanvasViewport(zoom: 1.5, offset: CGPoint(x: -40, y: 25))
        let anchor = CGPoint(x: 300, y: 200)
        let before = start.contentPoint(atScreen: anchor)
        for target in [0.5, 2.0, 3.7] {
            let after = start.zoomed(to: target, around: anchor)
            let point = after.contentPoint(atScreen: anchor)
            #expect(abs(point.x - before.x) < 1e-9)
            #expect(abs(point.y - before.y) < 1e-9)
            #expect(after.zoom == target)
        }
    }

    @Test func zoomClampsToRange() {
        let v = CanvasViewport()
        #expect(v.zoomed(to: 100, around: .zero).zoom == 4.0)
        #expect(v.zoomed(to: 0.001, around: .zero).zoom == 0.1)
        #expect(CanvasViewport.clamp(.nan) == 1)
        // Clamped zoom still keeps the anchor fixed.
        let anchor = CGPoint(x: 50, y: 60)
        let z = v.zoomed(to: 100, around: anchor)
        #expect(z.contentPoint(atScreen: anchor) == v.contentPoint(atScreen: anchor))
    }

    @Test func panMovesOffset() {
        let v = CanvasViewport(zoom: 2, offset: CGPoint(x: 10, y: 10)).panned(by: CGSize(width: 5, height: -3))
        #expect(v.offset == CGPoint(x: 15, y: 7))
        #expect(v.zoom == 2)
    }

    @Test func clampKeepsMarginVisible() {
        let content = CGSize(width: 1000, height: 600)
        let view = CGSize(width: 800, height: 500)
        let far = CanvasViewport(zoom: 1, offset: CGPoint(x: -5000, y: 9000)).clamped(content: content, viewport: view, margin: 80)
        #expect(far.offset == CGPoint(x: -920, y: 420))
        let inside = CanvasViewport(zoom: 1, offset: CGPoint(x: 20, y: -30)).clamped(content: content, viewport: view, margin: 80)
        #expect(inside.offset == CGPoint(x: 20, y: -30))
        // Zoom scales the content length that must stay reachable.
        let zoomed = CanvasViewport(zoom: 0.1, offset: CGPoint(x: -5000, y: 0)).clamped(content: content, viewport: view, margin: 80)
        #expect(abs(zoomed.offset.x - (-20)) < 1e-9)   // 80 of the 100 points shown must stay on screen
    }

    @Test func fittingCentresRect() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let v = CanvasViewport.fitting(rect, in: CGSize(width: 800, height: 600), padding: 0)
        #expect(v.zoom == 4.0)   // 800/200 = 4, capped at the range
        let center = v.contentPoint(atScreen: CGPoint(x: 400, y: 300))
        #expect(abs(center.x - rect.midX) < 1e-9)
        #expect(abs(center.y - rect.midY) < 1e-9)
        let capped = CanvasViewport.fitting(rect, in: CGSize(width: 800, height: 600), padding: 0, maxZoom: 1)
        #expect(capped.zoom == 1)
        let big = CanvasViewport.fitting(CGRect(x: 0, y: 0, width: 4000, height: 1000), in: CGSize(width: 800, height: 600), padding: 0)
        #expect(abs(big.zoom - 0.2) < 1e-9)
    }

    @Test func degenerateInputsFallBack() {
        #expect(CanvasViewport.fitting(.zero, in: CGSize(width: 800, height: 600)) == CanvasViewport())
    }
}
