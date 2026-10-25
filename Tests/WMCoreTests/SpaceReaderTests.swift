import Foundation
import Testing
@testable import WMCore

/// Tests for the pure parsing of SLSCopyManagedDisplaySpaces data. No system calls are made.
@Suite struct SpaceReaderTests {
    // MARK: Fixture, shaped like real SkyLight data

    private static func fullScreen(id: Int, pid: Int, wid: Int, app: String, uuid: String) -> [String: Any] {
        [
            "ManagedSpaceID": id,
            "id64": id,
            "type": 4,
            "uuid": uuid,
            "pid": pid,
            "fs_wid": wid,
            "TileLayoutManager": [
                "Age": 18037.79,
                "TileSpaces": [
                    [
                        "ManagedSpaceID": id,
                        "TileType": "Primary",
                        "TileWindowID": wid,
                        "appName": app,
                        "fs_wid": wid,
                        "id64": id + 2,
                        "name": "\(app) window",
                        "pid": pid,
                        "type": 5,
                        "uuid": "TILE-\(uuid)",
                    ] as [String: Any]
                ],
            ] as [String: Any],
            "WallSpace": ["ManagedSpaceID": id, "id64": id + 1, "type": 6, "uuid": "WALL-\(uuid)"] as [String: Any],
        ]
    }

    private static func desktop(id: Int, uuid: String) -> [String: Any] {
        ["ManagedSpaceID": id, "id64": id, "type": 0, "uuid": uuid]
    }

    private static let mainDisplay = "Main"
    private static let secondDisplay = "37D8832A-2D66-02CA-B9F7-8F30A301B230"

    private static func fixture() -> [[String: Any]] {
        [
            [
                "Display Identifier": mainDisplay,
                "Current Space": desktop(id: 1, uuid: ""),
                "Spaces": [
                    fullScreen(id: 37, pid: 1325, wid: 84, app: "Google Chrome", uuid: "B06E6C95"),
                    fullScreen(id: 82, pid: 19362, wid: 759, app: "Telegram", uuid: "4E69A47D"),
                    desktop(id: 1, uuid: ""),
                    fullScreen(id: 59, pid: 9419, wid: 337, app: "Arc", uuid: "0E62F489"),
                    fullScreen(id: 53, pid: 7922, wid: 296, app: "Claude", uuid: "55993B55"),
                ],
            ],
            [
                "Display Identifier": secondDisplay,
                "Current Space": desktop(id: 67, uuid: "D5C58298"),
                "Spaces": [
                    fullScreen(id: 73, pid: 11955, wid: 506, app: "Code", uuid: "4BFECBB3"),
                    desktop(id: 67, uuid: "D5C58298"),
                ],
            ],
        ]
    }

    // MARK: Tests

    @Test func parsesBothDisplaysInOrder() {
        let displays = SpaceReader.parse(Self.fixture())
        #expect(displays.count == 2)
        #expect(displays[0].displayIdentifier == "Main")
        #expect(displays[1].displayIdentifier == Self.secondDisplay)
        #expect(displays[0].displayName == nil)
        #expect(displays[0].spaces.map(\.id) == [37, 82, 1, 59, 53])
        #expect(displays[1].spaces.map(\.id) == [73, 67])
    }

    @Test func indexesAreZeroBasedPerDisplay() {
        let displays = SpaceReader.parse(Self.fixture())
        #expect(displays[0].spaces.map(\.index) == [0, 1, 2, 3, 4])
        #expect(displays[1].spaces.map(\.index) == [0, 1])
    }

    @Test func kindsFollowTheTypeKey() {
        let displays = SpaceReader.parse(Self.fixture())
        #expect(displays[0].spaces.map(\.kind) == [.fullscreen, .fullscreen, .desktop, .fullscreen, .fullscreen])
        #expect(displays[1].spaces.map(\.kind) == [.fullscreen, .desktop])
    }

    @Test func currentSpaceIsFlaggedOncePerDisplay() {
        let displays = SpaceReader.parse(Self.fixture())
        #expect(displays[0].currentSpaceID == 1)
        #expect(displays[0].spaces.map(\.isCurrent) == [false, false, true, false, false])
        #expect(displays[0].currentSpace?.kind == .desktop)
        #expect(displays[1].currentSpaceID == 67)
        #expect(displays[1].spaces.map(\.isCurrent) == [false, true])
    }

    @Test func fullScreenOwnersComeFromTheTileData() {
        let main = SpaceReader.parse(Self.fixture())[0]
        #expect(main.spaces.map(\.ownerAppNames) == [["Google Chrome"], ["Telegram"], [], ["Arc"], ["Claude"]])
        #expect(main.spaces.map(\.fullScreenOwnerPID) == [1325, 19362, nil, 9419, 7922])
        #expect(main.spaces.map(\.fullScreenWindowIDs) == [[84], [759], [], [337], [296]])
        #expect(main.spaces.allSatisfy { !$0.isSplitView })

        let second = SpaceReader.parse(Self.fixture())[1]
        #expect(second.spaces[0].ownerAppNames == ["Code"])
        #expect(second.spaces[1].ownerAppNames.isEmpty)
        #expect(second.spaces[1].fullScreenOwnerPID == nil)
    }

    @Test func desktopNumbersSkipFullScreenSpaces() {
        let displays = SpaceReader.parse(Self.fixture())
        #expect(displays[0].spaces.map { displays[0].desktopNumber(of: $0) } == [nil, nil, 1, nil, nil])
        #expect(displays[1].spaces.map { displays[1].desktopNumber(of: $0) } == [nil, 1])
    }

    @Test func uuidsAreKeptAndMayBeEmpty() {
        let main = SpaceReader.parse(Self.fixture())[0]
        #expect(main.spaces[0].uuid == "B06E6C95")
        #expect(main.spaces[2].uuid == "")
    }

    @Test func idFallsBackToManagedSpaceID() {
        let raw: [[String: Any]] = [[
            "Display Identifier": "Main",
            "Current Space": ["ManagedSpaceID": 5, "type": 0] as [String: Any],
            "Spaces": [["ManagedSpaceID": 5, "type": 0] as [String: Any]],
        ]]
        let displays = SpaceReader.parse(raw)
        #expect(displays[0].spaces.map(\.id) == [5])
        #expect(displays[0].spaces[0].isCurrent)
    }

    @Test func splitViewHasSeveralWindowsAndOwners() {
        var space = Self.fullScreen(id: 90, pid: 100, wid: 11, app: "Safari", uuid: "SPLIT")
        var layout = space["TileLayoutManager"] as! [String: Any]
        var tiles = layout["TileSpaces"] as! [[String: Any]]
        tiles.append(["TileType": "Secondary", "TileWindowID": 12, "appName": "Notes", "fs_wid": 12, "pid": 200])
        layout["TileSpaces"] = tiles
        space["TileLayoutManager"] = layout

        let raw: [[String: Any]] = [[
            "Display Identifier": "Main",
            "Current Space": space,
            "Spaces": [space],
        ]]
        let info = SpaceReader.parse(raw)[0].spaces[0]
        #expect(info.isSplitView)
        #expect(info.fullScreenWindowIDs == [11, 12])
        #expect(info.ownerAppNames == ["Safari", "Notes"])
        #expect(info.fullScreenOwnerPID == 100)
    }

    @Test func otherSpaceTypesKeepTheirRawNumber() {
        let raw: [[String: Any]] = [[
            "Display Identifier": "Main",
            "Current Space": ["id64": 2, "type": 2] as [String: Any],
            "Spaces": [["id64": 2, "type": 2] as [String: Any]],
        ]]
        let info = SpaceReader.parse(raw)[0].spaces[0]
        #expect(info.kind == .other(2))
        #expect(info.kind.rawType == 2)
    }

    @Test func lookupsAreUsedWhenGiven() {
        let lookups = SpaceReader.Lookups(
            displayName: { $0 == "Main" ? "Built-in Display" : nil },
            appName: { $0 == 1325 ? "Chrome (from pid)" : nil }
        )
        let main = SpaceReader.parse(Self.fixture(), lookups: lookups)[0]
        #expect(main.displayName == "Built-in Display")
        // Tile name first, pid-resolved name added when it differs.
        #expect(main.spaces[0].ownerAppNames == ["Google Chrome", "Chrome (from pid)"])
        #expect(SpaceReader.parse(Self.fixture(), lookups: lookups)[1].displayName == nil)
    }

    @Test func missingCurrentSpaceUsesTheLookup() {
        var raw = Self.fixture()
        raw[0]["Current Space"] = nil
        let lookups = SpaceReader.Lookups(currentSpace: { $0 == "Main" ? 59 : nil })
        let main = SpaceReader.parse(raw, lookups: lookups)[0]
        #expect(main.currentSpaceID == 59)
        #expect(main.spaces.first { $0.isCurrent }?.id == 59)
    }

    @Test func emptyInputGivesNoDisplays() {
        #expect(SpaceReader.parse([]).isEmpty)
    }

    @Test func jsonRoundTrip() throws {
        let displays = SpaceReader.parse(Self.fixture())
        let data = try JSONEncoder().encode(displays)
        let decoded = try JSONDecoder().decode([DisplaySpaces].self, from: data)
        #expect(decoded == displays)

        let kinds: [SpaceKind] = [.desktop, .fullscreen, .other(2)]
        let kindData = try JSONEncoder().encode(kinds)
        #expect(String(data: kindData, encoding: .utf8) == "[\"desktop\",\"fullscreen\",\"other:2\"]")
        #expect(try JSONDecoder().decode([SpaceKind].self, from: kindData) == kinds)
    }
}
