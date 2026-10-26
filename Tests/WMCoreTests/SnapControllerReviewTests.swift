import CoreGraphics
import Foundation
import Testing
@testable import WMCore

// Review finding 4: mouse-up must only commit a zone that is highlighted (state .snapping with a non-nil zoneID)
// and under the pointer. Anything else cancels.
@Suite struct SnapControllerReviewTests {
    private static let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private static let layout = LayoutPreset.halves.makeLayout()
    private static let display = SnapDisplay(id: "D1", frame: frame, layout: layout)
    private static let window = SnapWindow(id: 7, frame: CGRect(x: 100, y: 100, width: 400, height: 300))
    private static let moved = CGRect(x: 300, y: 100, width: 400, height: 300)

    private static func pressed(debounce: Double) -> SnapController {
        var c = SnapController(settings: SnapSettings(debounce: debounce))
        _ = c.mouseDown(at: CGPoint(x: 150, y: 110), window: window)
        return c
    }

    @Test func mouseUpBeforeDebounceElapsesCancels() {
        var c = Self.pressed(debounce: 0.2)
        // Pointer enters the left zone; the highlight is still debouncing (zoneID nil).
        let entered = c.dragged(to: CGPoint(x: 200, y: 200), flags: .option, display: Self.display,
                                windowFrame: Self.moved, at: 0)
        #expect(entered == .stateChanged(.snapping(windowID: 7, display: Self.display, zoneID: nil)))
        // Release before the debounce has elapsed: nothing is highlighted, so nothing may snap.
        let out = c.mouseUp(at: CGPoint(x: 200, y: 200), flags: .option, display: Self.display)
        #expect(out == .cancel)
        #expect(c.state == .idle)
    }

    @Test func mouseUpOverDifferentZoneThanHighlightedCancels() {
        var c = Self.pressed(debounce: 0.2)
        let left = Self.layout.zones[0].id
        _ = c.dragged(to: CGPoint(x: 200, y: 200), flags: .option, display: Self.display,
                      windowFrame: Self.moved, at: 0)
        _ = c.dragged(to: CGPoint(x: 210, y: 200), flags: .option, display: Self.display, at: 0.25)
        // Left zone is now highlighted; the pointer moves to the right zone and releases before it is highlighted.
        _ = c.dragged(to: CGPoint(x: 700, y: 200), flags: .option, display: Self.display, at: 0.3)
        #expect(c.state == .snapping(windowID: 7, display: Self.display, zoneID: left))
        let out = c.mouseUp(at: CGPoint(x: 700, y: 200), flags: .option, display: Self.display)
        #expect(out == .cancel)
    }
}
