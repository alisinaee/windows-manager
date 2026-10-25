import Foundation
import Testing
@testable import WMCore

/// Tests for the pure parts of FullScreenProbe: placement classification, order diff and matching helpers.
/// No system calls are made.
@Suite struct FullScreenProbeTests {
    // MARK: Fixtures

    private static func desktop(_ id: UInt64, uuid: String? = nil) -> SpaceInfo {
        SpaceInfo(id: id, uuid: uuid ?? "DESKTOP-\(id)", kind: .desktop, index: 0, isCurrent: false)
    }

    private static func fullScreen(_ id: UInt64, app: String = "App", pid: Int32 = 100, wid: UInt32 = 10) -> SpaceInfo {
        SpaceInfo(id: id, uuid: "FS-\(id)", kind: .fullscreen, index: 0, isCurrent: false,
                  fullScreenOwnerPID: pid, fullScreenWindowIDs: [wid], ownerAppNames: [app])
    }

    /// Builds a display; indexes and the current flag are filled in from the arguments.
    private static func display(_ spaces: [SpaceInfo], current: UInt64, id: String = "Main") -> DisplaySpaces {
        var list = spaces
        for i in list.indices {
            list[i].index = i
            list[i].isCurrent = list[i].id == current
        }
        return DisplaySpaces(displayIdentifier: id, displayName: nil, currentSpaceID: current, spaces: list)
    }

    private static let d1 = desktop(1)
    private static let d2 = desktop(2)
    private static let d3 = desktop(3)

    // MARK: classifyPlacement

    @Test func rightAfterTheOriginDesktopWhileStandingElsewhere() {
        let before = Self.display([Self.d1, Self.d2, Self.d3], current: 3)
        let after = Self.display([Self.d1, Self.fullScreen(10), Self.d2, Self.d3], current: 10)
        let placement = FullScreenProbe.classifyPlacement(before: before, after: after, originSpaceID: 1,
                                                          currentSpaceID: 3, newSpaceID: 10)
        #expect(placement == .afterOrigin)
        #expect(FullScreenProbe.placementMatches(before: before, after: after, originSpaceID: 1,
                                                 currentSpaceID: 3, newSpaceID: 10) == [.afterOrigin])
    }

    @Test func rightAfterTheCurrentSpace() {
        let before = Self.display([Self.d1, Self.d2, Self.d3], current: 2)
        let after = Self.display([Self.d1, Self.d2, Self.fullScreen(10), Self.d3], current: 10)
        let placement = FullScreenProbe.classifyPlacement(before: before, after: after, originSpaceID: 1,
                                                          currentSpaceID: 2, newSpaceID: 10)
        #expect(placement == .afterCurrent)
    }

    @Test func atTheEndOfTheList() {
        let before = Self.display([Self.d1, Self.d2, Self.d3], current: 1)
        let after = Self.display([Self.d1, Self.d2, Self.d3, Self.fullScreen(10)], current: 10)
        let placement = FullScreenProbe.classifyPlacement(before: before, after: after, originSpaceID: 1,
                                                          currentSpaceID: 1, newSpaceID: 10)
        #expect(placement == .end)
    }

    @Test func elsewhereReportsTheIndex() {
        let before = Self.display([Self.d1, Self.d2, Self.d3], current: 1)

        let atStart = Self.display([Self.fullScreen(10), Self.d1, Self.d2, Self.d3], current: 10)
        #expect(FullScreenProbe.classifyPlacement(before: before, after: atStart, originSpaceID: 1,
                                                  currentSpaceID: 1, newSpaceID: 10) == .other(0))

        let betweenOthers = Self.display([Self.d1, Self.d2, Self.fullScreen(10), Self.d3], current: 10)
        #expect(FullScreenProbe.classifyPlacement(before: before, after: betweenOthers, originSpaceID: 1,
                                                  currentSpaceID: 1, newSpaceID: 10) == .other(2))
    }

    @Test func ambiguousCasesListEveryMatchAndPreferTheMostSpecific() {
        let before = Self.display([Self.d1, Self.d2, Self.d3], current: 1)

        // Origin is also the current Space.
        let afterFirst = Self.display([Self.d1, Self.fullScreen(10), Self.d2, Self.d3], current: 10)
        #expect(FullScreenProbe.placementMatches(before: before, after: afterFirst, originSpaceID: 1,
                                                 currentSpaceID: 1, newSpaceID: 10) == [.afterOrigin, .afterCurrent])
        #expect(FullScreenProbe.classifyPlacement(before: before, after: afterFirst, originSpaceID: 1,
                                                  currentSpaceID: 1, newSpaceID: 10) == .afterOrigin)

        // Origin is the last Space, so "after origin" and "end" are the same position.
        let afterLast = Self.display([Self.d1, Self.d2, Self.d3, Self.fullScreen(10)], current: 10)
        #expect(FullScreenProbe.placementMatches(before: before, after: afterLast, originSpaceID: 3,
                                                 currentSpaceID: 1, newSpaceID: 10) == [.afterOrigin, .end])
    }

    @Test func existingFullScreenSpacesBetweenOriginAndNewSpaceMeanNotAfterOrigin() {
        // The new Space lands after the origin's existing full-screen Space, not directly after the origin.
        let existing = Self.fullScreen(5, app: "Notes", pid: 200, wid: 50)
        let before = Self.display([Self.d1, existing, Self.d2], current: 1)
        let after = Self.display([Self.d1, existing, Self.fullScreen(10), Self.d2], current: 10)
        #expect(FullScreenProbe.classifyPlacement(before: before, after: after, originSpaceID: 1,
                                                  currentSpaceID: 1, newSpaceID: 10) == .other(2))

        // Standing on that full-screen Space makes it "after current".
        let standing = Self.display([Self.d1, existing, Self.d2], current: 5)
        #expect(FullScreenProbe.classifyPlacement(before: standing, after: after, originSpaceID: 1,
                                                  currentSpaceID: 5, newSpaceID: 10) == .afterCurrent)
    }

    @Test func spacesThatAppearedMeanwhileAreIgnored() {
        // Space 99 is new as well (not in `before`); the answer is judged against the old Spaces only.
        let before = Self.display([Self.d1, Self.d2], current: 1)
        let after = Self.display([Self.d1, Self.desktop(99), Self.fullScreen(10), Self.d2], current: 10)
        #expect(FullScreenProbe.classifyPlacement(before: before, after: after, originSpaceID: 1,
                                                  currentSpaceID: 1, newSpaceID: 10) == .afterOrigin)

        let atEnd = Self.display([Self.d1, Self.d2, Self.fullScreen(10), Self.desktop(99)], current: 10)
        #expect(FullScreenProbe.placementMatches(before: before, after: atEnd, originSpaceID: 1,
                                                 currentSpaceID: 1, newSpaceID: 10) == [.end])
    }

    @Test func aReorderedListIsJudgedByTheFinalNeighbours() {
        // Auto-rearrange swapped D1 and D2; the new Space sits right after D1 in the final list.
        let before = Self.display([Self.d1, Self.d2, Self.d3], current: 1)
        let after = Self.display([Self.d2, Self.d1, Self.fullScreen(10), Self.d3], current: 10)
        #expect(FullScreenProbe.classifyPlacement(before: before, after: after, originSpaceID: 1,
                                                  currentSpaceID: 3, newSpaceID: 10) == .afterOrigin)
    }

    @Test func missingOriginAndCurrentFallBackToEndOrOther() {
        let before = Self.display([Self.d1, Self.d2], current: 1)
        let atEnd = Self.display([Self.d1, Self.d2, Self.fullScreen(10)], current: 10)
        #expect(FullScreenProbe.classifyPlacement(before: before, after: atEnd, originSpaceID: nil,
                                                  currentSpaceID: nil, newSpaceID: 10) == .end)
        let inside = Self.display([Self.d1, Self.fullScreen(10), Self.d2], current: 10)
        #expect(FullScreenProbe.classifyPlacement(before: before, after: inside, originSpaceID: nil,
                                                  currentSpaceID: nil, newSpaceID: 10) == .other(1))
    }

    @Test func aNewSpaceThatIsNotInTheListGivesMinusOne() {
        let before = Self.display([Self.d1], current: 1)
        let after = Self.display([Self.d1], current: 1)
        #expect(FullScreenProbe.classifyPlacement(before: before, after: after, originSpaceID: 1,
                                                  currentSpaceID: 1, newSpaceID: 10) == .other(-1))
    }

    @Test func onlySpaceInTheListIsAtTheEnd() {
        let before = Self.display([], current: 0)
        let after = Self.display([Self.fullScreen(10)], current: 10)
        #expect(FullScreenProbe.classifyPlacement(before: before, after: after, originSpaceID: nil,
                                                  currentSpaceID: nil, newSpaceID: 10) == .end)
    }

    @Test func placementDescriptionsAreStable() {
        #expect(Placement.end.description == "end")
        #expect(Placement.afterOrigin.description == "after-origin")
        #expect(Placement.afterCurrent.description == "after-current")
        #expect(Placement.other(3).description == "other(index 3)")
    }

    // MARK: diffOrder

    @Test func identicalListsHaveNoDiff() {
        let list = Self.display([Self.d1, Self.fullScreen(5), Self.d2], current: 1)
        let diff = FullScreenProbe.diffOrder(before: list, after: list)
        #expect(diff.isEmpty)
        #expect(diff.added.isEmpty && diff.removed.isEmpty && diff.movedIDs.isEmpty)
        #expect(!diff.reordered && !diff.currentChanged)
    }

    @Test func enteringFullScreenAddsOneSpaceAndChangesTheCurrentSpace() {
        let before = Self.display([Self.d1, Self.d2], current: 1)
        let after = Self.display([Self.d1, Self.fullScreen(10, app: "TextEdit"), Self.d2], current: 10)
        let diff = FullScreenProbe.diffOrder(before: before, after: after)
        #expect(diff.added.map(\.id) == [10])
        #expect(diff.added.first?.index == 1)
        #expect(diff.removed.isEmpty)
        #expect(diff.movedIDs.isEmpty)
        #expect(diff.currentBefore == 1 && diff.currentAfter == 10)
        #expect(diff.currentChanged)
        #expect(!diff.isEmpty)
    }

    @Test func exitingFullScreenRemovesTheSpace() {
        let before = Self.display([Self.d1, Self.fullScreen(10), Self.d2], current: 10)
        let after = Self.display([Self.d1, Self.d2], current: 1)
        let diff = FullScreenProbe.diffOrder(before: before, after: after)
        #expect(diff.removed.map(\.id) == [10])
        #expect(diff.removed.first?.index == 1)
        #expect(diff.added.isEmpty)
        #expect(!diff.reordered)
    }

    @Test func aSingleMovedSpaceIsReportedAlone() {
        let before = Self.display([Self.d1, Self.d2, Self.d3, Self.fullScreen(5)], current: 1)
        // D3 jumps to the front; D1, D2 and the full-screen Space keep their relative order.
        let after = Self.display([Self.d3, Self.d1, Self.d2, Self.fullScreen(5)], current: 1)
        let diff = FullScreenProbe.diffOrder(before: before, after: after)
        #expect(diff.movedIDs == [3])
        #expect(diff.reordered)
        #expect(diff.added.isEmpty && diff.removed.isEmpty)
    }

    @Test func anAddedSpaceDoesNotCountAsAMove() {
        let before = Self.display([Self.d1, Self.d2, Self.d3], current: 1)
        let after = Self.display([Self.d1, Self.fullScreen(10), Self.d2, Self.d3], current: 1)
        let diff = FullScreenProbe.diffOrder(before: before, after: after)
        #expect(diff.movedIDs.isEmpty)
        #expect(diff.added.map(\.id) == [10])
    }

    @Test func aFullReversalMovesAllButOne() {
        let before = Self.display([Self.d1, Self.d2, Self.d3], current: 1)
        let after = Self.display([Self.d3, Self.d2, Self.d1], current: 1)
        let diff = FullScreenProbe.diffOrder(before: before, after: after)
        #expect(diff.movedIDs.count == 2)
        #expect(diff.reordered)
    }

    // MARK: Order helper

    @Test func orderSortsIDsIntoDisplayOrder() {
        let display = Self.display([Self.d1, Self.fullScreen(11), Self.d2, Self.fullScreen(10)], current: 1)
        #expect(FullScreenProbe.order(of: [10, 11], in: display) == [11, 10])
        #expect(FullScreenProbe.order(of: [10, 99], in: display) == [10])
        #expect(FullScreenProbe.order(of: [], in: display).isEmpty)
    }

    // MARK: Ownership and home Space

    @Test func ownershipIsMatchedByWindowIDFirst() {
        let display = Self.display([Self.d1, Self.fullScreen(10, app: "Notes", pid: 200, wid: 50),
                                    Self.fullScreen(11, app: "TextEdit", pid: 100, wid: 60)], current: 1)
        let hit = FullScreenProbe.ownedFullScreenSpace(windowID: 60, pid: 999, in: [display])
        #expect(hit?.space.id == 11)
        #expect(hit?.matchedBy == "window id")
        #expect(FullScreenProbe.ownedFullScreenSpace(windowID: 61, pid: 999, in: [display]) == nil)
    }

    @Test func pidFallbackNeedsExactlyOneUnknownCandidate() {
        let known = Self.fullScreen(10, app: "TextEdit", pid: 100, wid: 60)
        let fresh = Self.fullScreen(11, app: "TextEdit", pid: 100, wid: 61)
        let display = Self.display([Self.d1, known, fresh], current: 1)

        // The window id 77 matches nothing; the pid matches both Spaces, so it is ambiguous.
        #expect(FullScreenProbe.ownedFullScreenSpace(windowID: 77, pid: 100, in: [display]) == nil)
        // Excluding the Space that already existed leaves one candidate.
        let hit = FullScreenProbe.ownedFullScreenSpace(windowID: 77, pid: 100, in: [display], excluding: [10])
        #expect(hit?.space.id == 11)
        #expect(hit?.matchedBy == "pid")
    }

    @Test func ownershipSearchesEveryDisplay() {
        let first = Self.display([Self.d1], current: 1, id: "Main")
        let second = Self.display([Self.desktop(7), Self.fullScreen(70, wid: 5)], current: 7, id: "OTHER")
        let hit = FullScreenProbe.ownedFullScreenSpace(windowID: 5, pid: 100, in: [first, second])
        #expect(hit?.display.displayIdentifier == "OTHER")
    }

    @Test func homeSpacePrefersTheCurrentDesktop() {
        let display = Self.display([Self.d1, Self.d2, Self.d3, Self.fullScreen(10)], current: 2)
        // A window set to "all Desktops" reports every Desktop; the current one wins.
        #expect(FullScreenProbe.homeSpace(ofWindowSpaces: [1, 2, 3], in: [display])?.space.id == 2)
        #expect(FullScreenProbe.homeSpace(ofWindowSpaces: [3], in: [display])?.space.id == 3)
        // Desktops win over full-screen Spaces; a full-screen Space is the fallback.
        #expect(FullScreenProbe.homeSpace(ofWindowSpaces: [10, 3], in: [display])?.space.id == 3)
        #expect(FullScreenProbe.homeSpace(ofWindowSpaces: [10], in: [display])?.space.id == 10)
        #expect(FullScreenProbe.homeSpace(ofWindowSpaces: [42], in: [display]) == nil)
        #expect(FullScreenProbe.homeSpace(ofWindowSpaces: [], in: [display]) == nil)
    }

    // MARK: Menu titles

    @Test func menuTitlesAreWhitelisted() {
        #expect(FullScreenProbe.menuTitleMatches("Enter Full Screen", entering: true))
        #expect(!FullScreenProbe.menuTitleMatches("Enter Full Screen", entering: false))
        #expect(FullScreenProbe.menuTitleMatches("Exit Full Screen", entering: false))
        #expect(!FullScreenProbe.menuTitleMatches("Exit Full Screen", entering: true))
        #expect(FullScreenProbe.menuTitleMatches("Full Screen", entering: true))
        #expect(FullScreenProbe.menuTitleMatches("Full Screen", entering: false))
        #expect(FullScreenProbe.menuTitleMatches("Toggle Full Screen", entering: nil))
        #expect(FullScreenProbe.menuTitleMatches("enter full screen", entering: nil))
        #expect(FullScreenProbe.menuTitleMatches("Leave Full Screen", entering: false))
        #expect(FullScreenProbe.menuTitleMatches("Enter Full Screen…", entering: true))
        #expect(FullScreenProbe.menuTitleMatches("Enter\u{00A0}Full Screen", entering: true))
        #expect(FullScreenProbe.menuTitleMatches("  Exit Fullscreen  ", entering: nil))
    }

    @Test func unrelatedMenuTitlesDoNotMatch() {
        for title in ["Always Show Toolbar in Full Screen", "Show Tab Bar", "Zoom", "Enter Presentation Mode",
                      "Full Screen Mode Options", "", "Fill", "Move & Resize"] {
            #expect(!FullScreenProbe.menuTitleMatches(title, entering: nil), "\(title) should not match")
        }
    }

    // MARK: Raw fromSpace data

    private static func rawFullScreen(id: Int, from: Any?, tileFrom: Any? = nil) -> [String: Any] {
        var entry: [String: Any] = ["id64": id, "ManagedSpaceID": id, "type": 4, "uuid": "FS-\(id)"]
        if let from { entry["fromSpace"] = from }
        var tile: [String: Any] = ["TileWindowID": 5, "appName": "TextEdit", "type": 5]
        if let tileFrom { tile["fromSpace"] = tileFrom }
        entry["TileLayoutManager"] = ["TileSpaces": [tile]] as [String: Any]
        return entry
    }

    @Test func rawParsingFindsFromSpaceOnTheEntryOrTheTile() {
        let raw: [[String: Any]] = [[
            "Display Identifier": "Main",
            "Spaces": [
                ["id64": 1, "type": 0, "uuid": ""] as [String: Any],
                Self.rawFullScreen(id: 10, from: "DESKTOP-2"),
                Self.rawFullScreen(id: 11, from: nil, tileFrom: "DESKTOP-3"),
                Self.rawFullScreen(id: 12, from: nil),
            ],
        ]]
        let info = FullScreenProbe.parseRawFullScreen(raw)
        #expect(Set(info.keys) == [10, 11, 12])
        #expect(info[10]?.fromSpace == "DESKTOP-2")
        #expect(info[11]?.fromSpace == "DESKTOP-3")
        #expect(info[12]?.fromSpace == nil)
        #expect(info[11]?.keys.contains("tile.fromSpace") == true)
        #expect(info[10]?.keys.contains("fromSpace") == true)
        #expect(info[12]?.keys.contains("TileLayoutManager") == true)
    }

    @Test func fromSpaceResolvesByUUIDIdOrEmptyUUID() {
        let first = Self.desktop(1, uuid: "")
        let display = Self.display([first, Self.desktop(2, uuid: "AB-CD"), Self.fullScreen(10)], current: 1)
        #expect(FullScreenProbe.resolveFromSpace("ab-cd", in: display)?.id == 2)
        #expect(FullScreenProbe.resolveFromSpace("", in: display)?.id == 1)
        #expect(FullScreenProbe.resolveFromSpace("2", in: display)?.id == 2)
        #expect(FullScreenProbe.resolveFromSpace("NOPE", in: display) == nil)
    }

    // MARK: Fixtures round-trip through the real parser

    @Test func parsedDisplaysWorkWithTheHelpers() {
        func fs(_ id: Int, wid: Int, app: String) -> [String: Any] {
            ["id64": id, "ManagedSpaceID": id, "type": 4, "uuid": "FS-\(id)", "pid": 300, "fs_wid": wid,
             "TileLayoutManager": ["TileSpaces": [["appName": app, "pid": 300, "fs_wid": wid]]] as [String: Any]]
        }
        func raw(_ spaces: [[String: Any]], current: Int) -> [[String: Any]] {
            [["Display Identifier": "Main", "Current Space": ["id64": current, "type": 0] as [String: Any], "Spaces": spaces]]
        }
        let desk1: [String: Any] = ["id64": 1, "type": 0, "uuid": ""]
        let desk2: [String: Any] = ["id64": 2, "type": 0, "uuid": "D2"]
        let before = SpaceReader.parse(raw([desk1, desk2], current: 1))[0]
        let after = SpaceReader.parse(raw([desk1, fs(10, wid: 77, app: "TextEdit"), desk2], current: 10))[0]

        #expect(FullScreenProbe.classifyPlacement(before: before, after: after, originSpaceID: 1,
                                                  currentSpaceID: 1, newSpaceID: 10) == .afterOrigin)
        let owned = FullScreenProbe.ownedFullScreenSpace(windowID: 77, pid: 300, in: [after])
        #expect(owned?.space.id == 10)
        #expect(FullScreenProbe.diffOrder(before: before, after: after).added.map(\.id) == [10])
    }
}
