import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Tests for monitor matching, frame mapping and coordinate conversion. They use made-up displays only,
/// shaped like the user's Mac: a 2560x1440 external main display and a 1512x982 built-in one to its right.
@Suite struct DisplayMapTests {
    // MARK: Fixtures (global top-left coordinates)

    /// A display whose visible frame is the frame minus a menu bar at the top.
    private static func display(_ uuid: String, name: String = "Display", vendor: UInt32 = 0, model: UInt32 = 0,
                                serial: UInt32 = 0, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                                menuBar: CGFloat = 25, main: Bool = false, builtIn: Bool = false) -> DisplayIdentity {
        DisplayIdentity(
            uuid: uuid, name: name, vendorID: vendor, modelID: model, serial: serial,
            frame: CGRect(x: x, y: y, width: width, height: height),
            visibleFrame: CGRect(x: x, y: y + menuBar, width: width, height: height - menuBar),
            isMain: main, isBuiltIn: builtIn, scale: builtIn ? 2 : 1
        )
    }

    private static func samsung(uuid: String = "SAMSUNG", x: CGFloat = 0, y: CGFloat = 0, main: Bool = true,
                                serial: UInt32 = 0x1111) -> DisplayIdentity {
        display(uuid, name: "U32R59x", vendor: 0x4C2D, model: 0x0F7B, serial: serial, x: x, y: y,
                width: 2560, height: 1440, main: main)
    }

    private static func builtIn(uuid: String = "BUILTIN", x: CGFloat = 2560, y: CGFloat = 458,
                                main: Bool = false) -> DisplayIdentity {
        display(uuid, name: "Built-in", vendor: 0x0610, model: 0xA050, serial: 0, x: x, y: y,
                width: 1512, height: 982, menuBar: 38, main: main, builtIn: true)
    }

    private static func approximately(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.001) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    private func uuids(_ result: [String: DisplayIdentity]) -> [String: String] {
        result.mapValues { $0.uuid }
    }

    // MARK: match: each fallback level

    @Test func exactUUIDWinsEvenWhenTheArrangementIsSwapped() {
        let saved = [Self.samsung(), Self.builtIn()]
        // Same two monitors, but now the built-in display is on the left and the Samsung one is on the right.
        let live = [
            Self.builtIn(x: 0, y: 0, main: true),
            Self.samsung(x: 1512, y: 100, main: false),
        ]
        #expect(uuids(DisplayMap.match(saved: saved, current: live)) == ["SAMSUNG": "SAMSUNG", "BUILTIN": "BUILTIN"])
    }

    @Test func exactUUIDIgnoresCase() {
        let saved = [Self.samsung(uuid: "abc-123")]
        let live = [Self.samsung(uuid: "ABC-123")]
        #expect(DisplayMap.match(saved: saved, current: live)["abc-123"]?.uuid == "ABC-123")
    }

    @Test func vendorModelSerialMatchesWhenTheUUIDChanged() {
        let saved = [Self.samsung(uuid: "OLD", serial: 0x1111)]
        // A decoy with the same vendor and model but another serial comes first in the list.
        let live = [
            Self.samsung(uuid: "OTHER-UNIT", x: 0, y: 0, main: true, serial: 0x2222),
            Self.samsung(uuid: "NEW", x: 2560, y: 0, main: false, serial: 0x1111),
        ]
        #expect(DisplayMap.match(saved: saved, current: live)["OLD"]?.uuid == "NEW")
    }

    @Test func vendorModelAndSizeMatchWhenTheSerialDiffers() {
        let saved = [Self.samsung(uuid: "OLD", serial: 0x1111)]
        let live = [
            // Same size but a different monitor model.
            Self.display("DECOY", vendor: 0x1234, model: 0x5678, x: 0, y: 0, width: 2560, height: 1440, main: true),
            Self.samsung(uuid: "SAME-MODEL", x: 2560, y: 0, main: false, serial: 0x9999),
        ]
        #expect(DisplayMap.match(saved: saved, current: live)["OLD"]?.uuid == "SAME-MODEL")
    }

    @Test func sameSizeMatchesWhenTheHardwareDiffers() {
        let saved = [Self.display("OLD", vendor: 0x1, model: 0x2, x: 0, y: 0, width: 1920, height: 1080, main: true)]
        let live = [
            Self.display("WIDE", vendor: 0x9, model: 0x9, x: 0, y: 0, width: 3440, height: 1440, main: true),
            Self.display("FHD", vendor: 0x7, model: 0x8, x: 3440, y: 0, width: 1920, height: 1080),
        ]
        #expect(DisplayMap.match(saved: saved, current: live)["OLD"]?.uuid == "FHD")
    }

    @Test func unknownHardwareIDsDoNotMatchByHardware() {
        // Both have vendor 0 and model 0; only the size and role decide. Here nothing is the same size.
        let saved = [Self.display("OLD", x: 0, y: 0, width: 1920, height: 1080, main: true)]
        let live = [
            Self.display("SECOND", x: 3000, y: 0, width: 1024, height: 768),
            Self.display("MAIN", x: 0, y: 0, width: 1280, height: 800, main: true),
        ]
        // Role (main with main) beats the order of the list.
        #expect(DisplayMap.match(saved: saved, current: live)["OLD"]?.uuid == "MAIN")
    }

    @Test func builtInMatchesBuiltInByRole() {
        // A different Mac: other UUIDs, other sizes, so only the role is left.
        let saved = [
            Self.display("EXT-OLD", vendor: 0x1, model: 0x1, x: 0, y: 0, width: 2560, height: 1440, main: true),
            Self.display("LAPTOP-OLD", vendor: 0x2, model: 0x2, x: 2560, y: 0, width: 1440, height: 900, builtIn: true),
        ]
        let live = [
            Self.display("EXT-NEW", vendor: 0x3, model: 0x3, x: 0, y: 0, width: 1920, height: 1080, main: true),
            Self.display("LAPTOP-NEW", vendor: 0x4, model: 0x4, x: 1920, y: 0, width: 1728, height: 1117, builtIn: true),
        ]
        #expect(uuids(DisplayMap.match(saved: saved, current: live)) == ["EXT-OLD": "EXT-NEW", "LAPTOP-OLD": "LAPTOP-NEW"])
    }

    @Test func builtInRoleBeatsMainRoleWhenTheLaptopWasMain() {
        // Saved: the laptop alone (built-in is main). Live: an external monitor is main, the built-in is second.
        let saved = [Self.display("LAPTOP-OLD", vendor: 0x2, model: 0x2, x: 0, y: 0, width: 1440, height: 900,
                                  main: true, builtIn: true)]
        let live = [
            Self.display("EXT", vendor: 0x3, model: 0x3, x: 0, y: 0, width: 1920, height: 1080, main: true),
            Self.display("LAPTOP-NEW", vendor: 0x4, model: 0x4, x: 1920, y: 0, width: 1728, height: 1117, builtIn: true),
        ]
        #expect(DisplayMap.match(saved: saved, current: live)["LAPTOP-OLD"]?.uuid == "LAPTOP-NEW")
    }

    @Test func mainMatchesMainByRole() {
        let saved = [Self.display("OLD-MAIN", vendor: 0x1, model: 0x1, x: 0, y: 0, width: 2560, height: 1440, main: true)]
        let live = [
            Self.display("LEFT", vendor: 0x3, model: 0x3, x: -1920, y: 0, width: 1920, height: 1080),
            Self.display("NEW-MAIN", vendor: 0x4, model: 0x4, x: 0, y: 0, width: 1728, height: 1117, main: true),
        ]
        #expect(DisplayMap.match(saved: saved, current: live)["OLD-MAIN"]?.uuid == "NEW-MAIN")
    }

    @Test func lastResortUsesTheMainDisplayThenAFreeOne() {
        // Neither saved display has a UUID, hardware, size or role in common with the live ones.
        let saved = [
            Self.display("A", vendor: 0x1, model: 0x1, x: 0, y: 0, width: 1000, height: 700),
            Self.display("B", vendor: 0x2, model: 0x2, x: 1000, y: 0, width: 1100, height: 700),
        ]
        let live = [
            Self.display("SECOND", vendor: 0x8, model: 0x8, x: 1500, y: 0, width: 1600, height: 900),
            Self.display("MAIN", vendor: 0x9, model: 0x9, x: 0, y: 0, width: 1500, height: 900, main: true),
        ]
        let result = uuids(DisplayMap.match(saved: saved, current: live))
        // The first saved display takes the live main display, the next one the free display.
        #expect(result == ["A": "MAIN", "B": "SECOND"])
    }

    @Test func sameSizeBeatsTheMainRole() {
        // The saved non-main display has the size of the live main display, so it takes it (step 4);
        // the saved main display then gets the free live display.
        let saved = [
            Self.display("A", vendor: 0x1, model: 0x1, x: 1000, y: 0, width: 1500, height: 900),
            Self.display("B-MAIN", vendor: 0x2, model: 0x2, x: 0, y: 0, width: 1100, height: 700, main: true),
        ]
        let live = [
            Self.display("L1", vendor: 0x8, model: 0x8, x: 0, y: 0, width: 1500, height: 900, main: true),
            Self.display("L2", vendor: 0x9, model: 0x9, x: 1500, y: 0, width: 1600, height: 900),
        ]
        #expect(uuids(DisplayMap.match(saved: saved, current: live)) == ["A": "L1", "B-MAIN": "L2"])
    }

    // MARK: match: more saved than live, one-to-one, identical monitors

    @Test func moreSavedThanLiveShareTheMainDisplay() {
        let saved = [Self.samsung(), Self.builtIn(), Self.display("THIRD", vendor: 0x7, model: 0x7, x: 4072, y: 0,
                                                                  width: 1920, height: 1080)]
        let live = [Self.builtIn(x: 0, y: 0, main: true)]
        let result = uuids(DisplayMap.match(saved: saved, current: live))
        // The built-in display keeps its own match; the others share the only (main) display.
        #expect(result == ["BUILTIN": "BUILTIN", "SAMSUNG": "BUILTIN", "THIRD": "BUILTIN"])
    }

    @Test func moreSavedThanLiveKeepsTheExactMatchOnItsOwnDisplay() {
        let saved = [Self.samsung(), Self.builtIn()]
        let live = [Self.samsung(main: true)]
        let result = uuids(DisplayMap.match(saved: saved, current: live))
        #expect(result == ["SAMSUNG": "SAMSUNG", "BUILTIN": "SAMSUNG"])
    }

    @Test func neverMapsTwoSavedDisplaysToOneLiveDisplayWhenThereAreEnough() {
        // Two saved displays of the same size and two live ones: each gets its own.
        let saved = [
            Self.display("S1", x: 0, y: 0, width: 1920, height: 1080, main: true),
            Self.display("S2", x: 1920, y: 0, width: 1920, height: 1080),
        ]
        let live = [
            Self.display("L1", x: 0, y: 0, width: 1920, height: 1080, main: true),
            Self.display("L2", x: 1920, y: 0, width: 1920, height: 1080),
        ]
        let result = DisplayMap.match(saved: saved, current: live)
        #expect(Set(result.values.map(\.uuid)) == ["L1", "L2"])
        #expect(result["S1"]?.uuid == "L1")
        #expect(result["S2"]?.uuid == "L2")
    }

    @Test func fewerSavedThanLiveLeavesTheOthersFree() {
        let saved = [Self.builtIn()]
        let live = [Self.samsung(), Self.builtIn(), Self.display("EXTRA", x: 4072, y: 0, width: 1920, height: 1080)]
        #expect(uuids(DisplayMap.match(saved: saved, current: live)) == ["BUILTIN": "BUILTIN"])
    }

    @Test func identicalMonitorsKeepTheirSideWhenSwapped() {
        // Two identical monitors (same model, serial 0); the left one is main. Their UUIDs changed, and the
        // live list has them in the opposite order. The closest corner decides, so left stays left.
        func monitor(_ uuid: String, x: CGFloat, main: Bool) -> DisplayIdentity {
            Self.display(uuid, vendor: 0x4C2D, model: 0x0F7B, x: x, y: 0, width: 2560, height: 1440, main: main)
        }
        let saved = [monitor("OLD-LEFT", x: 0, main: true), monitor("OLD-RIGHT", x: 2560, main: false)]
        let live = [monitor("NEW-RIGHT", x: 2560, main: false), monitor("NEW-LEFT", x: 0, main: true)]
        #expect(uuids(DisplayMap.match(saved: saved, current: live))
                == ["OLD-LEFT": "NEW-LEFT", "OLD-RIGHT": "NEW-RIGHT"])
    }

    @Test func emptyInputGivesAnEmptyResult() {
        #expect(DisplayMap.match(saved: [], current: [Self.samsung()]).isEmpty)
        #expect(DisplayMap.match(saved: [Self.samsung()], current: []).isEmpty)
    }

    @Test func matchReturnsTheLiveDisplayNotTheSavedOne() {
        let saved = [Self.samsung(uuid: "OLD", x: 0, y: 0)]
        let live = [Self.samsung(uuid: "OLD", x: 100, y: 50)]
        #expect(DisplayMap.match(saved: saved, current: live)["OLD"]?.frame.origin == CGPoint(x: 100, y: 50))
    }

    // MARK: mapFrame

    @Test func sameDisplayKeepsTheFrameWhenItStillFits() {
        let saved = Self.samsung()
        let frame = CGRect(x: 300, y: 200, width: 1200, height: 800)
        #expect(DisplayMap.mapFrame(frame, from: saved, to: saved) == frame)
    }

    @Test func sameDisplayAfterAResolutionChangeKeepsAFrameThatStillFits() {
        let saved = Self.samsung()
        let live = Self.display("SAMSUNG", x: 0, y: 0, width: 1920, height: 1080, main: true)
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(DisplayMap.mapFrame(frame, from: saved, to: live) == frame)
    }

    @Test func sameDisplayThatMovedInTheArrangementKeepsItsPlaceOnTheDisplay() {
        let saved = Self.builtIn(x: 2560, y: 458)
        let live = Self.builtIn(x: 0, y: 0, main: true)
        let frame = CGRect(x: 2560 + 100, y: 458 + 150, width: 700, height: 500)
        #expect(DisplayMap.mapFrame(frame, from: saved, to: live) == CGRect(x: 100, y: 150, width: 700, height: 500))
    }

    @Test func clampsAFrameThatNoLongerFitsOnTheSameDisplay() {
        let saved = Self.samsung()
        let live = Self.display("SAMSUNG", x: 0, y: 0, width: 1920, height: 1080, main: true) // visible: y 25..1080
        let frame = CGRect(x: 1800, y: 1000, width: 600, height: 400) // sticks out right and bottom
        let result = DisplayMap.mapFrame(frame, from: saved, to: live)
        #expect(live.visibleFrame.contains(result))
        #expect(result.size == frame.size)
    }

    @Test func clampsAFrameThatStartsAboveTheVisibleArea() {
        let saved = Self.samsung()
        let frame = CGRect(x: 100, y: -200, width: 500, height: 400) // above the menu bar
        let result = DisplayMap.mapFrame(frame, from: saved, to: saved)
        #expect(result.minY == saved.visibleFrame.minY)
        #expect(abs(result.minX - 100) < 0.001)
        #expect(result.size == frame.size)
    }

    @Test func maximizedWindowStaysMaximizedOnASmallerDisplay() {
        let big = Self.samsung()
        let small = Self.builtIn()
        let result = DisplayMap.mapFrame(big.visibleFrame, from: big, to: small)
        #expect(Self.approximately(result, small.visibleFrame))
    }

    @Test func leftAndRightHalvesStayHalvesOnASmallerDisplay() {
        let big = Self.samsung()
        let small = Self.builtIn()
        let left = CGRect(x: 0, y: 25, width: 1280, height: 1415)
        let right = CGRect(x: 1280, y: 25, width: 1280, height: 1415)
        let mappedLeft = DisplayMap.mapFrame(left, from: big, to: small)
        let mappedRight = DisplayMap.mapFrame(right, from: big, to: small)
        let v = small.visibleFrame
        #expect(abs(mappedLeft.width - v.width / 2) < 0.001)
        #expect(abs(mappedRight.width - v.width / 2) < 0.001)
        #expect(mappedLeft.minX == v.minX)
        #expect(abs(mappedRight.maxX - v.maxX) < 0.001)
        #expect(abs(mappedLeft.maxX - mappedRight.minX) < 0.001)
        #expect(mappedLeft.height == v.height)
    }

    @Test func aSmallWindowKeepsItsSizeOnASmallerDisplay() {
        let big = Self.samsung()
        let small = Self.builtIn()
        let frame = CGRect(x: 1000, y: 500, width: 600, height: 400) // fits on the small display
        let result = DisplayMap.mapFrame(frame, from: big, to: small)
        #expect(result.size == frame.size)
        #expect(small.visibleFrame.contains(result))
    }

    @Test func aCenteredWindowStaysCenteredOnASmallerDisplay() {
        let big = Self.samsung()
        let small = Self.builtIn()
        let v = big.visibleFrame
        let frame = CGRect(x: v.midX - 400, y: v.midY - 300, width: 800, height: 600)
        let result = DisplayMap.mapFrame(frame, from: big, to: small)
        #expect(abs(result.midX - small.visibleFrame.midX) < 0.001)
        #expect(abs(result.midY - small.visibleFrame.midY) < 0.001)
    }

    @Test func aWindowAtTheRightEdgeStaysAtTheRightEdgeOnABiggerDisplay() {
        let small = Self.builtIn()
        let big = Self.samsung()
        let v = small.visibleFrame
        let frame = CGRect(x: v.maxX - 500, y: v.maxY - 400, width: 500, height: 400) // bottom-right corner
        let result = DisplayMap.mapFrame(frame, from: small, to: big)
        #expect(result.size == frame.size)
        #expect(abs(result.maxX - big.visibleFrame.maxX) < 0.001)
        #expect(abs(result.maxY - big.visibleFrame.maxY) < 0.001)
    }

    @Test func differentDisplaysOfTheSameSizeMoveByTheDisplayOffset() {
        let a = Self.display("A", x: 0, y: 0, width: 1920, height: 1080, main: true)
        let b = Self.display("B", x: 1920, y: -200, width: 1920, height: 1080)
        let frame = CGRect(x: 120, y: 240, width: 800, height: 500)
        #expect(DisplayMap.mapFrame(frame, from: a, to: b) == CGRect(x: 2040, y: 40, width: 800, height: 500))
    }

    @Test func aWindowLargerThanTheTargetIsAlwaysShrunkInsideIt() {
        let big = Self.samsung()
        let small = Self.builtIn()
        let frame = CGRect(x: -100, y: -50, width: 3000, height: 1800) // bigger than the big display itself
        let result = DisplayMap.mapFrame(frame, from: big, to: small)
        #expect(small.visibleFrame.contains(result))
    }

    @Test func aDisplayWithoutAVisibleAreaReturnsTheFrameUnchanged() {
        let saved = Self.samsung()
        var broken = Self.builtIn()
        broken.visibleFrame = .zero
        let frame = CGRect(x: 10, y: 10, width: 100, height: 100)
        #expect(DisplayMap.mapFrame(frame, from: saved, to: broken) == frame)
    }

    // MARK: Coordinates

    @Test func convertsTheMainDisplayBetweenCoordinateSpaces() {
        let bottomLeft = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(DisplayMap.toTopLeft(bottomLeft, mainHeight: 1440) == CGRect(x: 0, y: 0, width: 2560, height: 1440))
    }

    @Test func convertsTheBuiltInDisplayLikeTheUsersMac() {
        // NSScreen: the built-in display sits at y 0 (bottom-left); in top-left coordinates it starts at y 458.
        let nsFrame = CGRect(x: 2560, y: 0, width: 1512, height: 982)
        let topLeft = DisplayMap.toTopLeft(nsFrame, mainHeight: 1440)
        #expect(topLeft == CGRect(x: 2560, y: 458, width: 1512, height: 982))
        #expect(DisplayMap.toBottomLeft(topLeft, mainHeight: 1440) == nsFrame)
    }

    @Test func aDisplayAboveTheMainDisplayHasNegativeTopLeftY() {
        let nsFrame = CGRect(x: 0, y: 1440, width: 1920, height: 1080)
        #expect(DisplayMap.toTopLeft(nsFrame, mainHeight: 1440) == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    @Test func convertingBackAndForthGivesTheSameRect() {
        let rect = CGRect(x: -300, y: 77.5, width: 640.25, height: 480)
        let there = DisplayMap.toTopLeft(rect, mainHeight: 982)
        #expect(DisplayMap.toBottomLeft(there, mainHeight: 982) == rect)
    }

    @Test func convertsPoints() {
        #expect(DisplayMap.toTopLeft(CGPoint(x: 10, y: 100), mainHeight: 1440) == CGPoint(x: 10, y: 1340))
        #expect(DisplayMap.toBottomLeft(CGPoint(x: 10, y: 1340), mainHeight: 1440) == CGPoint(x: 10, y: 100))
    }

    @Test func defaultMainHeightIsTheRealMainDisplayHeight() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        let height = DisplayMap.mainDisplayHeight()
        #expect(DisplayMap.toTopLeft(rect) == DisplayMap.toTopLeft(rect, mainHeight: height))
    }

    // MARK: monitorSetKey

    @Test func monitorSetKeyIgnoresOrderCaseAndPlacement() {
        let a = [Self.samsung(uuid: "bbb"), Self.builtIn(uuid: "AAA")]
        let b = [Self.builtIn(uuid: "aaa", x: -1512, y: 10, main: true), Self.samsung(uuid: "BBB", x: 0, main: false)]
        #expect(DisplayMap.monitorSetKey(a) == "AAA+BBB")
        #expect(DisplayMap.monitorSetKey(a) == DisplayMap.monitorSetKey(b))
    }

    @Test func monitorSetKeyDiffersForADifferentSet() {
        let both = [Self.samsung(), Self.builtIn()]
        #expect(DisplayMap.monitorSetKey(both) != DisplayMap.monitorSetKey([Self.builtIn()]))
        #expect(DisplayMap.monitorSetKey([]) == "")
    }

    // MARK: display(containing:)

    @Test func picksTheDisplayWithTheLargestOverlap() {
        let displays = [Self.samsung(), Self.builtIn()]
        // 800 wide: 300 on the Samsung display, 500 on the built-in one.
        let frame = CGRect(x: 2260, y: 600, width: 800, height: 300)
        #expect(DisplayMap.display(containing: frame, in: displays)?.uuid == "BUILTIN")
        let mostlyLeft = CGRect(x: 2000, y: 600, width: 800, height: 300)
        #expect(DisplayMap.display(containing: mostlyLeft, in: displays)?.uuid == "SAMSUNG")
    }

    @Test func aFrameInsideOneDisplayBelongsToIt() {
        let displays = [Self.samsung(), Self.builtIn()]
        #expect(DisplayMap.display(containing: CGRect(x: 100, y: 100, width: 400, height: 300), in: displays)?.uuid == "SAMSUNG")
        #expect(DisplayMap.display(containing: CGRect(x: 3000, y: 700, width: 400, height: 300), in: displays)?.uuid == "BUILTIN")
    }

    @Test func aFrameOffEveryDisplayGoesToTheNearestOne() {
        let displays = [Self.samsung(), Self.builtIn()]
        let farRight = CGRect(x: 9000, y: 700, width: 400, height: 300)
        #expect(DisplayMap.display(containing: farRight, in: displays)?.uuid == "BUILTIN")
        let aboveBuiltIn = CGRect(x: 3000, y: 300, width: 400, height: 100) // just above the built-in display
        #expect(DisplayMap.display(containing: aboveBuiltIn, in: displays)?.uuid == "BUILTIN")
    }

    @Test func noDisplaysGivesNil() {
        #expect(DisplayMap.display(containing: CGRect(x: 0, y: 0, width: 10, height: 10), in: []) == nil)
    }

    @Test func overlapTieGoesToTheDisplayNearerTheCenter() {
        let left = Self.display("LEFT", x: 0, y: 0, width: 1000, height: 800, main: true)
        let right = Self.display("RIGHT", x: 1000, y: 0, width: 1000, height: 300)
        // 200x200 on each display; the frame's center (1000, 200) is closer to the center of the right one.
        let frame = CGRect(x: 800, y: 100, width: 400, height: 200)
        #expect(DisplayMap.display(containing: frame, in: [left, right])?.uuid == "RIGHT")
    }

    // MARK: Live system (read-only)

    @Test func currentReportsTheMainDisplayAtTheOrigin() {
        let displays = DisplayMap.current()
        guard !displays.isEmpty else { return } // headless machine
        let main = displays.filter(\.isMain)
        #expect(main.count == 1)
        #expect(main.first?.frame.origin == .zero)
        #expect(displays.allSatisfy { !$0.uuid.isEmpty })
        // The visible frame lies inside the frame.
        #expect(displays.allSatisfy { $0.frame.insetBy(dx: -1, dy: -1).contains($0.visibleFrame) })
        // Each reported UUID maps back to a CGDirectDisplayID.
        #expect(displays.allSatisfy { DisplayMap.cgDisplayID(for: $0.uuid) != nil })
    }

    @Test func currentFramesAgreeWithCoreGraphicsBounds() {
        for display in DisplayMap.current() {
            guard let id = DisplayMap.cgDisplayID(for: display.uuid) else { continue }
            #expect(display.frame == CGDisplayBounds(id))
        }
    }
}

/// Tests for the watcher's debounce and change detection. They use a private queue and a fake snapshot, so
/// no display change is needed.
@Suite struct DisplayWatcherTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(old: [DisplayIdentity], new: [DisplayIdentity], key: String, triggers: DisplayWatcher.Trigger)] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
        var last: (old: [DisplayIdentity], new: [DisplayIdentity], key: String, triggers: DisplayWatcher.Trigger)? {
            lock.lock(); defer { lock.unlock() }; return items.last
        }
        func add(_ old: [DisplayIdentity], _ new: [DisplayIdentity], _ key: String, _ triggers: DisplayWatcher.Trigger) {
            lock.lock(); items.append((old, new, key, triggers)); lock.unlock()
        }
    }

    private final class Screens: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [DisplayIdentity]
        init(_ value: [DisplayIdentity]) { self.value = value }
        var current: [DisplayIdentity] {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private static func screen(_ uuid: String, x: CGFloat = 0, main: Bool = true) -> DisplayIdentity {
        DisplayIdentity(uuid: uuid, name: uuid, frame: CGRect(x: x, y: 0, width: 1920, height: 1080),
                        visibleFrame: CGRect(x: x, y: 25, width: 1920, height: 1055), isMain: main, isBuiltIn: false)
    }

    private func makeWatcher(_ screens: Screens, _ recorder: Recorder) -> DisplayWatcher {
        var watcher: DisplayWatcher!
        watcher = DisplayWatcher(debounce: 0.05, queue: DispatchQueue(label: "DisplayWatcherTests"),
                                 snapshot: { screens.current },
                                 handler: { old, new, key in
            recorder.add(old, new, key, watcher.lastTriggers)
        })
        return watcher
    }

    @Test func sameLayoutIgnoresVisibleFramesAndOrder() {
        let a = [Self.screen("A"), Self.screen("B", x: 1920, main: false)]
        var b = [Self.screen("B", x: 1920, main: false), Self.screen("A")]
        b[0].visibleFrame = CGRect(x: 1920, y: 25, width: 1920, height: 900) // the Dock grew
        b[1].name = "renamed"
        #expect(DisplayWatcher.sameLayout(a, b))
        b[1].frame.origin.x = 5
        #expect(!DisplayWatcher.sameLayout(a, b))
        #expect(!DisplayWatcher.sameLayout(a, [Self.screen("A")]))
    }

    @Test func aRealChangeCallsTheHandlerOnceWithOldNewAndKey() async throws {
        let screens = Screens([Self.screen("A")])
        let recorder = Recorder()
        let watcher = makeWatcher(screens, recorder)
        watcher.start()
        defer { watcher.stop() }

        screens.current = [Self.screen("A"), Self.screen("B", x: 1920, main: false)]
        // Several notifications for one change collapse into one call.
        watcher.post(.displays); watcher.post(.displays); watcher.post(.displays)
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(recorder.count == 1)
        #expect(recorder.last?.old.map(\.uuid) == ["A"])
        #expect(recorder.last?.new.map(\.uuid) == ["A", "B"])
        #expect(recorder.last?.key == "A+B")
        #expect(recorder.last?.triggers == .displays)
    }

    @Test func aReconfigurationWithoutAChangeDoesNotCallTheHandler() async throws {
        let screens = Screens([Self.screen("A")])
        let recorder = Recorder()
        let watcher = makeWatcher(screens, recorder)
        watcher.start()
        defer { watcher.stop() }

        watcher.post(.displays)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count == 0)
    }

    @Test func wakeAndUnlockCallTheHandlerEvenWithoutAChange() async throws {
        let screens = Screens([Self.screen("A")])
        let recorder = Recorder()
        let watcher = makeWatcher(screens, recorder)
        watcher.start()
        defer { watcher.stop() }

        watcher.post(.wake)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count == 1)
        #expect(recorder.last?.triggers == .wake)

        watcher.post(.unlock)
        watcher.post(.wake)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count == 2)
        #expect(recorder.last?.triggers == [.wake, .unlock])
        #expect(recorder.last?.key == "A")
    }

    @Test func stoppingDropsAPendingCall() async throws {
        let screens = Screens([Self.screen("A")])
        let recorder = Recorder()
        let watcher = makeWatcher(screens, recorder)
        watcher.start()
        watcher.post(.wake)
        watcher.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count == 0)
        #expect(!watcher.isRunning)
    }
}
