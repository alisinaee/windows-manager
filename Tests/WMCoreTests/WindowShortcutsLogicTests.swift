import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite struct WindowShortcutsLogicTests {
    let visible = CGRect(x: 0, y: 25, width: 1200, height: 800)

    // MARK: Size cycling

    @Test func leftCyclesHalfTwoThirdsOneThird() {
        var frame = WindowSizeCycle.nextFrame(current: CGRect(x: 300, y: 200, width: 400, height: 300),
                                              visible: visible, direction: .left)
        #expect(frame == CGRect(x: 0, y: 25, width: 600, height: 800))
        frame = WindowSizeCycle.nextFrame(current: frame, visible: visible, direction: .left)
        #expect(abs(frame.width - 800) < 0.001 && frame.minX == 0 && frame.height == 800)
        frame = WindowSizeCycle.nextFrame(current: frame, visible: visible, direction: .left)
        #expect(abs(frame.width - 400) < 0.001 && frame.minX == 0)
        frame = WindowSizeCycle.nextFrame(current: frame, visible: visible, direction: .left)
        #expect(frame.width == 600 && frame.minX == 0)
    }

    @Test func rightAnchorsToTheRightEdge() {
        let frame = WindowSizeCycle.nextFrame(current: CGRect(x: 0, y: 25, width: 1200, height: 800),
                                              visible: visible, direction: .right)
        #expect(frame == CGRect(x: 600, y: 25, width: 600, height: 800))
    }

    @Test func topAndBottomCycleHeights() {
        let top = WindowSizeCycle.nextFrame(current: CGRect(x: 10, y: 500, width: 300, height: 300),
                                            visible: visible, direction: .top)
        #expect(top == CGRect(x: 0, y: 25, width: 1200, height: 400))
        let bottom = WindowSizeCycle.nextFrame(current: CGRect(x: 10, y: 500, width: 300, height: 300),
                                               visible: visible, direction: .bottom)
        #expect(bottom == CGRect(x: 0, y: 425, width: 1200, height: 400))
        let second = WindowSizeCycle.nextFrame(current: bottom, visible: visible, direction: .bottom)
        #expect(abs(second.height - 800 * 2 / 3) < 0.001 && abs(second.maxY - visible.maxY) < 0.001)
    }

    @Test func centerIsCentredOnTheVisibleFrame() {
        let frame = WindowSizeCycle.frame(for: .center, step: 0, visible: visible)
        #expect(frame == CGRect(x: 300, y: 225, width: 600, height: 400))
        #expect(frame.midX == visible.midX && frame.midY == visible.midY)
    }

    @Test func approximateMatchToleratesSmallDrift() {
        let drifted = CGRect(x: 2, y: 27, width: 598, height: 797)
        #expect(WindowSizeCycle.currentStep(of: drifted, direction: .left, visible: visible) == 0)
        // A window at the two-thirds width is step 1, so the next press goes to one-third.
        let twoThirds = CGRect(x: 0, y: 25, width: 800, height: 800)
        #expect(WindowSizeCycle.nextFrame(current: twoThirds, visible: visible, direction: .left).width == 400)
    }

    @Test func unmatchedWindowStartsAtHalf() {
        #expect(WindowSizeCycle.currentStep(of: CGRect(x: 0, y: 0, width: 123, height: 456),
                                            direction: .left, visible: visible) == nil)
        #expect(WindowSizeCycle.nextFrame(current: CGRect(x: 0, y: 0, width: 123, height: 456),
                                          visible: visible, direction: .left).width == 600)
    }

    // MARK: Move to display

    let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let top = CGRect(x: 0, y: -1080, width: 1440, height: 1080)

    @Test func movesToNextDisplayKeepingOffsetAndSize() {
        let window = CGRect(x: 100, y: 50, width: 500, height: 400)
        let moved = DisplayMove.targetFrame(current: window, displays: [left, right], direction: .next)
        #expect(moved == CGRect(x: 1540, y: 50, width: 500, height: 400))
    }

    @Test func previousWrapsAroundAndSortsLeftToRight() {
        // Displays given out of order: sorted order is top (x 0, y -1080), left (x 0, y 0), right.
        let window = CGRect(x: 1500, y: 100, width: 300, height: 200)
        let previous = DisplayMove.targetFrame(current: window, displays: [right, left, top], direction: .previous)
        // Right is last in sorted order, so "previous" from right is the display before it: left.
        #expect(previous == CGRect(x: 60, y: 100, width: 300, height: 200))
        let next = DisplayMove.targetFrame(current: window, displays: [right, left, top], direction: .next)
        // Next from right wraps to the first display, top.
        #expect(next == CGRect(x: 1500 - 1440, y: 100 - 1080, width: 300, height: 200))
    }

    @Test func clampsIntoSmallerTargetAndShrinksOversizedWindow() {
        let small = CGRect(x: 0, y: 0, width: 800, height: 600)
        let big = CGRect(x: 800, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: 1500, y: 700, width: 1500, height: 900)
        let moved = DisplayMove.targetFrame(current: window, displays: [big, small], direction: .next)
        #expect(moved == CGRect(x: 0, y: 0, width: 800, height: 600))
        // Offset from big's corner (1000, 900) is pulled back inside the smaller display: x 600, y 450.
        let edge = CGRect(x: 1800, y: 900, width: 200, height: 150)
        let back = DisplayMove.targetFrame(current: edge, displays: [small, big], direction: .next)
        #expect(back == CGRect(x: 600, y: 450, width: 200, height: 150))
    }

    @Test func singleDisplayHasNowhereToGo() {
        #expect(DisplayMove.targetFrame(current: CGRect(x: 0, y: 0, width: 10, height: 10),
                                        displays: [left], direction: .next) == nil)
    }

    @Test func windowOutsideAllDisplaysUsesMostOverlap() {
        // Centre (1400, 900) is in neither display; overlap is 14000 on left and 12000 on right.
        let window = CGRect(x: 1300, y: 800, width: 200, height: 200)
        #expect(DisplayMove.displayIndex(of: window, in: [left, right]) == 0)
        #expect(DisplayMove.displayIndex(of: CGRect(x: 5000, y: 5000, width: 1, height: 1), in: [left, right]) == 0)
        #expect(DisplayMove.displayIndex(of: window, in: []) == nil)
    }

    // MARK: Ignore list

    @Test func ignoreListAddRemoveAndContains() {
        var list = HotkeyIgnoreList()
        let firstAdd = list.add("com.example.game")
        let duplicateAdd = list.add("com.example.game")
        let blankAdd = list.add("   ")
        let terminalAdd = list.add("com.apple.Terminal")
        #expect(firstAdd)
        #expect(!duplicateAdd)
        #expect(!blankAdd)
        #expect(terminalAdd)
        #expect(list.contains("com.example.game"))
        #expect(!list.contains(nil))
        #expect(!list.contains("com.other"))
        let removed = list.remove("com.example.game")
        let removedAgain = list.remove("com.example.game")
        #expect(removed)
        #expect(!removedAgain)
        #expect(list.bundleIDs == ["com.apple.Terminal"])
    }

    @Test func ignoreListRoundTripsThroughDefaults() throws {
        let suiteName = "WindowShortcutsLogicTests.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        #expect(HotkeyIgnoreList.load(from: suite).bundleIDs.isEmpty)
        var list = HotkeyIgnoreList()
        list.add("com.apple.Terminal")
        list.add("com.example.rdp")
        list.save(to: suite)
        #expect(suite.stringArray(forKey: "hotkeyIgnoredApps") == ["com.apple.Terminal", "com.example.rdp"])
        #expect(HotkeyIgnoreList.load(from: suite) == list)
    }
}
