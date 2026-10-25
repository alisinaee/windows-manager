import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Tests for the pure logic around the Mission Control driver. Nothing here opens Mission Control
/// or touches the system.
@Suite struct MissionControlDriverTests {
    // MARK: Fixtures

    private static func desktop(_ id: UInt64, index: Int, current: Bool = false) -> SpaceInfo {
        SpaceInfo(id: id, uuid: "", kind: .desktop, index: index, isCurrent: current)
    }

    private static func fullScreen(_ id: UInt64, index: Int) -> SpaceInfo {
        SpaceInfo(id: id, uuid: "FS-\(id)", kind: .fullscreen, index: index, isCurrent: false,
                  fullScreenOwnerPID: 100, fullScreenWindowIDs: [9], ownerAppNames: ["Safari"])
    }

    /// Desktop 1 (id 1, current), full-screen (id 37), Desktop 2 (id 2), Desktop 3 (id 3).
    private static func display() -> DisplaySpaces {
        DisplaySpaces(displayIdentifier: "Main", displayName: nil, currentSpaceID: 1, spaces: [
            desktop(1, index: 0, current: true),
            fullScreen(37, index: 1),
            desktop(2, index: 2),
            desktop(3, index: 3),
        ])
    }

    private static func window(_ id: UInt32, spaces: [UInt64], size: CGFloat = 800, alpha: Double = 1,
                               app: String = "Notes") -> CatalogWindow {
        CatalogWindow(windowID: id, pid: 50, appName: app, title: nil,
                      bounds: CGRect(x: 0, y: 0, width: size, height: size), alpha: alpha, spaceIDs: spaces)
    }

    private func refusal(_ id: UInt64, windows: Int = 0, force: Bool = false) -> DesktopRemovalRefusal? {
        let display = Self.display()
        let space = display.spaces.first { $0.id == id }!
        return DesktopRemovalPolicy.refusal(for: space, in: display, blockingWindowCount: windows, force: force)
    }

    // MARK: Removal refusal rules

    @Test func plainDesktopMayBeRemoved() {
        #expect(refusal(2) == nil)
        #expect(refusal(3) == nil)
    }

    @Test func desktopOneIsRefused() {
        #expect(refusal(1) == .firstDesktop)
    }

    @Test func fullScreenSpaceIsRefused() {
        #expect(refusal(37) == .notADesktop(.fullscreen))
    }

    @Test func currentSpaceIsRefused() {
        var display = Self.display()
        display.currentSpaceID = 2
        display.spaces[0].isCurrent = false
        display.spaces[2].isCurrent = true
        let space = display.spaces[2]
        #expect(DesktopRemovalPolicy.refusal(for: space, in: display, blockingWindowCount: 0, force: false)
            == .currentSpace)
        // Even if only the display's current id says so.
        var other = space
        other.isCurrent = false
        #expect(DesktopRemovalPolicy.refusal(for: other, in: display, blockingWindowCount: 0, force: false)
            == .currentSpace)
    }

    @Test func windowsBlockUnlessForced() {
        #expect(refusal(2, windows: 2) == .hasWindows(2))
        #expect(refusal(2, windows: 2, force: true) == nil)
    }

    @Test func forceDoesNotOverrideOtherRules() {
        #expect(refusal(1, windows: 1, force: true) == .firstDesktop)
        #expect(refusal(37, force: true) == .notADesktop(.fullscreen))
        #expect(DesktopRemovalRefusal.hasWindows(1).canForce)
        #expect(!DesktopRemovalRefusal.firstDesktop.canForce)
        #expect(!DesktopRemovalRefusal.currentSpace.canForce)
        #expect(!DesktopRemovalRefusal.notADesktop(.fullscreen).canForce)
    }

    @Test func otherSpaceKindIsRefused() {
        let display = DisplaySpaces(displayIdentifier: "Main", displayName: nil, currentSpaceID: 1, spaces: [
            Self.desktop(1, index: 0, current: true),
            SpaceInfo(id: 9, uuid: "", kind: .other(2), index: 1, isCurrent: false),
        ])
        #expect(DesktopRemovalPolicy.refusal(for: display.spaces[1], in: display, blockingWindowCount: 0, force: true)
            == .notADesktop(.other(2)))
    }

    @Test func refusalMessagesMentionTheReason() {
        #expect(DesktopRemovalRefusal.hasWindows(3).description.contains("3 windows"))
        #expect(DesktopRemovalRefusal.hasWindows(1).description.contains("1 window "))
        #expect(DesktopRemovalRefusal.hasWindows(1).description.contains("--force"))
        #expect(DesktopRemovalRefusal.firstDesktop.description.contains("Desktop 1"))
        #expect(DesktopRemovalRefusal.notADesktop(.fullscreen).description.contains("full-screen"))
    }

    // MARK: Windows that would be stranded

    @Test func onlyWindowsOnThatDesktopBlock() {
        let windows = [
            Self.window(1, spaces: [2]),                       // on Desktop 2 only: blocks
            Self.window(2, spaces: [3]),                       // another Desktop
            Self.window(3, spaces: [1, 2, 3]),                 // all Desktops: stays visible elsewhere
            Self.window(4, spaces: [2], size: 40),             // tiny helper window
            Self.window(5, spaces: [2], alpha: 0),             // invisible
            Self.window(6, spaces: []),                        // on no Space
        ]
        let blocking = DesktopRemovalPolicy.blockingWindows(onSpace: 2, in: windows)
        #expect(blocking.map(\.windowID) == [1])
    }

    // MARK: Space diff

    @Test func diffFindsAddedAndRemoved() {
        let before = [Self.desktop(1, index: 0), Self.desktop(2, index: 1), Self.fullScreen(37, index: 2)]
        let afterAdd = before + [Self.desktop(4, index: 3)]
        #expect(SpacesDiff.between(before, afterAdd) == SpacesDiff(added: [4], removed: []))
        let afterRemove = [before[0], before[2]]
        #expect(SpacesDiff.between(before, afterRemove) == SpacesDiff(added: [], removed: [2]))
        #expect(SpacesDiff.between(before, before).isEmpty)
    }

    // MARK: Display matching

    private let main = DisplayGeometry(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    private let right = DisplayGeometry(displayID: 5, frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440))

    @Test func matchesByDisplayIDFirst() {
        // Groups listed in the opposite order of the displays: ids still win over position.
        let groups = [right, main]
        #expect(MissionControlDisplayMatcher.match(target: main, position: 0, targetCount: 2, groups: groups) == 1)
        #expect(MissionControlDisplayMatcher.match(target: right, position: 1, targetCount: 2, groups: groups) == 0)
    }

    @Test func matchesByFrameWhenIDIsMissing() {
        let groups = [
            DisplayGeometry(displayID: nil, frame: right.frame),
            DisplayGeometry(displayID: nil, frame: CGRect(x: 0.5, y: 0, width: 1512, height: 982)),
        ]
        #expect(MissionControlDisplayMatcher.match(target: main, position: 1, targetCount: 2, groups: groups) == 1)
    }

    @Test func fallsBackToPositionWhenCountsAgree() {
        let blind = [DisplayGeometry(), DisplayGeometry()]
        #expect(MissionControlDisplayMatcher.match(target: DisplayGeometry(), position: 1, targetCount: 2,
                                                   groups: blind) == 1)
        #expect(MissionControlDisplayMatcher.match(target: DisplayGeometry(), position: 0, targetCount: 1,
                                                   groups: [DisplayGeometry()]) == 0)
    }

    @Test func noMatchWhenNothingFits() {
        // Counts differ and neither id nor frame matches.
        let groups = [right]
        #expect(MissionControlDisplayMatcher.match(target: main, position: 0, targetCount: 2, groups: groups) == nil)
        // Position outside the list.
        let two = [DisplayGeometry(), DisplayGeometry()]
        #expect(MissionControlDisplayMatcher.match(target: DisplayGeometry(), position: 2, targetCount: 2,
                                                   groups: two) == nil)
        #expect(MissionControlDisplayMatcher.match(target: main, position: 0, targetCount: 1, groups: []) == nil)
    }

    @Test func ambiguousIDFallsThroughToFrame() {
        // Two groups report the same id (should not happen); the frame decides.
        let groups = [
            DisplayGeometry(displayID: 1, frame: right.frame),
            DisplayGeometry(displayID: 1, frame: main.frame),
        ]
        #expect(MissionControlDisplayMatcher.match(target: main, position: 0, targetCount: 2, groups: groups) == 1)
    }

    // MARK: Space buttons in the Spaces bar

    @Test func spaceButtonsDropTheAddButton() {
        let roles: [String?] = ["AXButton", "AXButton", "AXButton"]
        let ids: [String?] = [nil, nil, "mc.spaces.add"]
        #expect(MissionControlDisplayMatcher.spaceButtonIndices(roles: roles, identifiers: ids, expected: 2) == [0, 1])
    }

    @Test func spaceButtonsFallBackToButtonRole() {
        let roles: [String?] = ["AXButton", "AXGroup", "AXButton", "AXButton"]
        let ids: [String?] = [nil, nil, nil, nil]
        #expect(MissionControlDisplayMatcher.spaceButtonIndices(roles: roles, identifiers: ids, expected: 3) == [0, 2, 3])
    }

    @Test func spaceButtonsRefuseToGuess() {
        let roles: [String?] = ["AXButton", "AXButton"]
        let ids: [String?] = [nil, nil]
        #expect(MissionControlDisplayMatcher.spaceButtonIndices(roles: roles, identifiers: ids, expected: 3) == nil)
        #expect(MissionControlDisplayMatcher.spaceButtonIndices(roles: [], identifiers: [], expected: 1) == nil)
    }

    // MARK: Tree rendering

    @Test func rendersOneLinePerNode() {
        let tree = [
            AXTreeNode(role: "AXGroup", identifier: "mc", children: [
                AXTreeNode(role: "AXGroup", identifier: "mc.display", frame: CGRect(x: 0, y: 0, width: 100, height: 50),
                           displayID: 1, children: [
                    AXTreeNode(role: "AXButton", identifier: "mc.spaces.add", actions: ["AXPress"]),
                ]),
            ]),
        ]
        let lines = AXTreeNode.render(tree).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "AXGroup id=\"mc\"")
        #expect(lines[1] == "  AXGroup id=\"mc.display\" displayID=1 frame=0,0 100x50")
        #expect(lines[2] == "    AXButton id=\"mc.spaces.add\" actions=[AXPress]")
    }
}
