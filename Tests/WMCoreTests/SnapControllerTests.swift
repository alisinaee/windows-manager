import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite struct SnapControllerTests {
    private static let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private static let layout = LayoutPreset.halves.makeLayout()
    private static let display = SnapDisplay(id: "D1", frame: frame, layout: layout)
    private static let window = SnapWindow(id: 7, frame: CGRect(x: 100, y: 100, width: 400, height: 300))
    private static let moved = CGRect(x: 300, y: 100, width: 400, height: 300)

    private static func pressed(_ settings: SnapSettings = SnapSettings(debounce: 0)) -> SnapController {
        var c = SnapController(settings: settings)
        _ = c.mouseDown(at: CGPoint(x: 150, y: 110), window: window)
        return c
    }

    @Test func stateStartsIdleAndIgnoresDragsWithoutPress() {
        var c = SnapController()
        #expect(c.state == .idle)
        #expect(c.dragged(to: CGPoint(x: 500, y: 500), flags: .option, display: Self.display, windowFrame: Self.moved, at: 0) == .none)
        #expect(c.mouseUp(at: CGPoint(x: 100, y: 100), flags: .option, display: Self.display) == .none)
    }

    @Test func pressWithoutWindowIsIgnored() {
        var c = SnapController()
        _ = c.mouseDown(at: .zero, window: nil)
        #expect(!c.isActive)
    }

    @Test func belowMinimumDistanceNothingHappens() {
        var c = Self.pressed()
        let out = c.dragged(to: CGPoint(x: 153, y: 112), flags: .option, display: Self.display, windowFrame: Self.moved, at: 0)
        #expect(out == .none)
        #expect(c.state == .idle)
    }

    @Test func dragWithoutModifierIsPlainDragging() {
        var c = Self.pressed()
        let out = c.dragged(to: CGPoint(x: 400, y: 200), flags: [], display: Self.display, windowFrame: Self.moved, at: 0)
        #expect(out == .stateChanged(.dragging(windowID: 7)))
        #expect(c.mouseUp(at: CGPoint(x: 400, y: 200), flags: [], display: Self.display) == .cancel)
    }

    @Test func modifierShowsOverlayAndHighlightsZone() {
        var c = Self.pressed()
        let left = Self.layout.zones[0].id
        let out = c.dragged(to: CGPoint(x: 200, y: 200), flags: .option, display: Self.display, windowFrame: Self.moved, at: 0)
        #expect(out == .stateChanged(.snapping(windowID: 7, display: Self.display, zoneID: left)))
        #expect(c.needsWindowFrame == false)
    }

    @Test func mouseUpCommitsZoneFrame() {
        var c = Self.pressed()
        _ = c.dragged(to: CGPoint(x: 800, y: 200), flags: .option, display: Self.display, windowFrame: Self.moved, at: 0)
        let out = c.mouseUp(at: CGPoint(x: 800, y: 200), flags: .option, display: Self.display)
        #expect(out == .commit(windowID: 7, frame: CGRect(x: 500, y: 0, width: 500, height: 800)))
        #expect(c.state == .idle)
        #expect(!c.isActive)
    }

    @Test func gapIsAppliedToCommittedFrame() {
        var c = Self.pressed(SnapSettings(debounce: 0, gap: 10))
        _ = c.dragged(to: CGPoint(x: 200, y: 200), flags: .option, display: Self.display, windowFrame: Self.moved, at: 0)
        let out = c.mouseUp(at: CGPoint(x: 200, y: 200), flags: .option, display: Self.display)
        #expect(out == .commit(windowID: 7, frame: CGRect(x: 10, y: 10, width: 485, height: 780)))
    }

    @Test func releasingModifierBeforeMouseUpCancels() {
        var c = Self.pressed()
        _ = c.dragged(to: CGPoint(x: 200, y: 200), flags: .option, display: Self.display, windowFrame: Self.moved, at: 0)
        let out = c.flagsChanged([], at: CGPoint(x: 200, y: 200), display: Self.display, time: 0.1)
        #expect(out == .stateChanged(.dragging(windowID: 7)))
        #expect(c.mouseUp(at: CGPoint(x: 200, y: 200), flags: [], display: Self.display) == .cancel)
    }

    @Test func pressingModifierMidDragStartsSnapping() {
        var c = Self.pressed()
        _ = c.dragged(to: CGPoint(x: 200, y: 200), flags: [], display: Self.display, windowFrame: Self.moved, at: 0)
        let out = c.flagsChanged(.option, at: CGPoint(x: 200, y: 200), display: Self.display, time: 0.1)
        if case .stateChanged(.snapping) = out {} else { Issue.record("expected snapping, got \(out)") }
    }

    @Test func otherModifierDoesNotSnap() {
        var c = Self.pressed()
        let out = c.dragged(to: CGPoint(x: 200, y: 200), flags: .command, display: Self.display, windowFrame: Self.moved, at: 0)
        #expect(out == .stateChanged(.dragging(windowID: 7)))
    }

    @Test func configurableModifier() {
        var c = Self.pressed(SnapSettings(modifier: .control, debounce: 0))
        let out = c.dragged(to: CGPoint(x: 200, y: 200), flags: .control, display: Self.display, windowFrame: Self.moved, at: 0)
        if case .stateChanged(.snapping) = out {} else { Issue.record("expected snapping, got \(out)") }
    }

    @Test func resizeDragIsIgnored() {
        var c = Self.pressed()
        let resized = CGRect(x: 100, y: 100, width: 600, height: 300)
        #expect(c.dragged(to: CGPoint(x: 400, y: 200), flags: .option, display: Self.display, windowFrame: resized, at: 0) == .none)
        #expect(c.dragged(to: CGPoint(x: 410, y: 200), flags: .option, display: Self.display, windowFrame: Self.moved, at: 0.1) == .none)
        #expect(c.mouseUp(at: CGPoint(x: 410, y: 200), flags: .option, display: Self.display) == .none)
    }

    @Test func windowThatDidNotMoveIsNotADrag() {
        var c = Self.pressed()
        let out = c.dragged(to: CGPoint(x: 400, y: 200), flags: .option, display: Self.display, windowFrame: Self.window.frame, at: 0)
        #expect(out == .none)
        #expect(c.needsWindowFrame)
    }

    @Test func debounceDelaysZoneChange() {
        var c = Self.pressed(SnapSettings(debounce: 0.2))
        let left = Self.layout.zones[0].id
        let right = Self.layout.zones[1].id
        // First entry into a zone is also debounced.
        var out = c.dragged(to: CGPoint(x: 200, y: 200), flags: .option, display: Self.display, windowFrame: Self.moved, at: 0)
        #expect(out == .stateChanged(.snapping(windowID: 7, display: Self.display, zoneID: nil)))
        out = c.dragged(to: CGPoint(x: 210, y: 200), flags: .option, display: Self.display, at: 0.25)
        #expect(out == .stateChanged(.snapping(windowID: 7, display: Self.display, zoneID: left)))
        // Moving to the other zone: not yet highlighted.
        out = c.dragged(to: CGPoint(x: 700, y: 200), flags: .option, display: Self.display, at: 0.3)
        #expect(out == .none)
        out = c.tick(flags: .option, at: CGPoint(x: 700, y: 200), display: Self.display, time: 0.55)
        #expect(out == .stateChanged(.snapping(windowID: 7, display: Self.display, zoneID: right)))
    }

    @Test func leavingEveryZoneClearsHighlightAndCancelsOnRelease() {
        var c = Self.pressed()
        _ = c.dragged(to: CGPoint(x: 200, y: 200), flags: .option, display: Self.display, windowFrame: Self.moved, at: 0)
        let out = c.dragged(to: CGPoint(x: 1500, y: 200), flags: .option, display: Self.display, at: 0.1)
        #expect(out == .stateChanged(.snapping(windowID: 7, display: Self.display, zoneID: nil)))
        #expect(c.mouseUp(at: CGPoint(x: 1500, y: 200), flags: .option, display: Self.display) == .cancel)
    }

    @Test func noDisplayMeansNoOverlay() {
        var c = Self.pressed()
        let out = c.dragged(to: CGPoint(x: 200, y: 200), flags: .option, display: nil, windowFrame: Self.moved, at: 0)
        #expect(out == .stateChanged(.dragging(windowID: 7)))
    }

    @Test func disabledSettingIgnoresPress() {
        var c = SnapController(settings: SnapSettings(enabled: false))
        _ = c.mouseDown(at: .zero, window: Self.window)
        #expect(!c.isActive)
    }

    @Test func explicitCancelResets() {
        var c = Self.pressed()
        _ = c.dragged(to: CGPoint(x: 200, y: 200), flags: .option, display: Self.display, windowFrame: Self.moved, at: 0)
        #expect(c.cancel() == .cancel)
        #expect(c.state == .idle)
        #expect(c.cancel() == .none)
    }

    @Test func newPressWhileSnappingCancelsOldGesture() {
        var c = Self.pressed()
        _ = c.dragged(to: CGPoint(x: 200, y: 200), flags: .option, display: Self.display, windowFrame: Self.moved, at: 0)
        #expect(c.mouseDown(at: .zero, window: Self.window) == .cancel)
    }

    @Test func settingsCodableRoundTripAndDefaults() throws {
        let s = SnapSettings(enabled: true, modifier: .command, minimumDragDistance: 12, debounce: 0.1, gap: 4)
        let back = try JSONDecoder().decode(SnapSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let empty = try JSONDecoder().decode(SnapSettings.self, from: Data("{}".utf8))
        #expect(empty == SnapSettings())
        #expect(empty.modifier == .option)
    }
}
