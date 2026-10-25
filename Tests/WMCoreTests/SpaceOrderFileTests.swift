import Foundation
import Testing
@testable import WMCore

/// Tests for the pure parts of SpaceOrderFile: reading the stored order and rewriting it. No preferences are
/// read or written and no process is started. The fixture copies the shape of a real com.apple.spaces domain:
/// "Main" is stored under the real display UUID in ManagedSpaceOrdering (with one stale uuid), a stale "Main"
/// ordering entry is left behind, the second display's ordering entry holds stale uuids of other displays, and
/// the Monitors array contains entries without Spaces.
@Suite struct SpaceOrderFileTests {
    // MARK: Fixture

    static let mainUUID = "92A7EEBC-4739-4A6C-8F33-C306D98F06F6"
    static let extUUID = "37D8832A-2D66-02CA-B9F7-8F30A301B230"

    // Main display: FS Chrome, FS Telegram, Desktop 1 (empty uuid), FS Arc, FS Claude.
    static let chrome = "B06E6C95-B962-43D7-8B4B-414E2584D049"
    static let telegram = "4E69A47D-5647-4A6C-BA61-95EBCF8D3AF7"
    static let arc = "0E62F489-1A74-45FB-A019-A746DD759B31"
    static let claude = "55993B55-5979-4D8A-BBBD-5CDCE6764725"
    // External display: FS Code, FS Code, Desktop.
    static let code1 = "4BFECBB3-22F9-480B-AB0A-FA467F85FD72"
    static let code2 = "82045E33-EA22-4A11-8305-46468ED3F2FA"
    static let extDesktop = "D5C58298-6128-EB52-F266-30F5D656251E"

    static let mainOrder = [chrome, telegram, "", arc, claude]
    static let extOrder = [code1, code2, extDesktop]

    static func space(_ uuid: String, id: Int, type: Int, app: String? = nil) -> [String: Any] {
        var dict: [String: Any] = ["id64": id, "ManagedSpaceID": id, "type": type, "uuid": uuid]
        if let app {
            dict["pid"] = id + 1000
            dict["fs_wid"] = id + 2000
            dict["TileLayoutManager"] = [
                "Age": 13680.350579750002,
                "TileSpaces": [["appName": app, "id64": id + 2, "type": 5, "uuid": "TILE-\(uuid)"] as [String: Any]],
            ] as [String: Any]
        }
        return dict
    }

    static func mainSpaces() -> [[String: Any]] {
        [
            space(chrome, id: 37, type: 4, app: "Google Chrome"),
            space(telegram, id: 82, type: 4, app: "Telegram"),
            space("", id: 1, type: 0),
            space(arc, id: 59, type: 4, app: "Arc"),
            space(claude, id: 53, type: 4, app: "Claude"),
        ]
    }

    static func extSpaces() -> [[String: Any]] {
        [
            space(code1, id: 73, type: 4, app: "Code"),
            space(code2, id: 103, type: 4, app: "Code"),
            space(extDesktop, id: 67, type: 0),
        ]
    }

    static func monitors() -> [[String: Any]] {
        [
            ["Display Identifier": "Main", "Spaces": mainSpaces(), "Current Space": space("", id: 1, type: 0)],
            ["Display Identifier": extUUID, "Spaces": extSpaces(), "Current Space": space(extDesktop, id: 67, type: 0)],
            ["Display Identifier": "F9807639-7070-4BB1-8BA4-11AF2E8F9052"],
            ["Display Identifier": "8168851E-00E7-406B-B64B-0CE3DFE3DB83"],
        ]
    }

    static func ordering() -> [[String: Any]] {
        [
            ["ManagedDisplayID": mainUUID, "ManagedSpaceIDs": mainOrder + [code1]],
            ["ManagedDisplayID": "Main", "ManagedSpaceIDs": [""]],
            ["ManagedDisplayID": extUUID, "ManagedSpaceIDs": ["", chrome, arc, claude] + extOrder],
        ]
    }

    enum Layout {
        /// Real macOS 26 shape: both arrays below "Management Data".
        case managementData
        /// Both arrays directly below SpacesDisplayConfiguration.
        case flat
        /// Monitors exist in two places.
        case monitorsTwice
        case noOrdering
        case noMonitors
    }

    static func config(_ layout: Layout = .managementData) -> [String: Any] {
        let assignments: [String: Any] = [
            "ManagedSpaceOrdering": ordering(),
            "ManagedSpaceAssignments": [["ManagedDisplayID": [mainUUID], "ManagedSpaceID": arc] as [String: Any]],
        ]
        var inner: [String: Any]
        switch layout {
        case .managementData:
            inner = ["Management Data": ["Monitors": monitors(), "SpaceAssignments": assignments,
                                         "Age": 70616.44654125001, "Management Mode": 1] as [String: Any]]
        case .flat:
            inner = ["Monitors": monitors(), "SpaceAssignments": assignments]
        case .monitorsTwice:
            inner = ["Management Data": ["Monitors": monitors(), "SpaceAssignments": assignments] as [String: Any],
                     "Monitors": monitors()]
        case .noOrdering:
            inner = ["Management Data": ["Monitors": monitors()] as [String: Any]]
        case .noMonitors:
            inner = ["Management Data": ["SpaceAssignments": assignments] as [String: Any]]
        }
        inner["Space Properties"] = [["name": "", "windows": [65, 426]] as [String: Any]]
        return ["SpacesDisplayConfiguration": inner, "spans-displays": false]
    }

    // MARK: Helpers

    static func display(_ id: String, in config: [String: Any]) -> StoredDisplayOrder? {
        SpaceOrderFile.parseStoredOrder(config).first { $0.displayIdentifier == id }
    }

    static func same(_ a: Any?, _ b: Any?) -> Bool { SpaceOrderFile.isEqual(a, b) }

    static func error(_ body: () throws -> Any) -> SpaceOrderFileError? {
        do {
            _ = try body()
            return nil
        } catch let error as SpaceOrderFileError {
            return error
        } catch {
            return nil
        }
    }

    static func isUnexpectedShape(_ error: SpaceOrderFileError?) -> Bool {
        if case .unexpectedShape? = error { return true }
        return false
    }

    static func isSetMismatch(_ error: SpaceOrderFileError?) -> Bool {
        if case .spaceSetMismatch? = error { return true }
        return false
    }

    // MARK: parseStoredOrder

    @Test func parseReadsEveryDisplayThatHasSpaces() throws {
        let displays = SpaceOrderFile.parseStoredOrder(Self.config())
        #expect(displays.map(\.displayIdentifier) == ["Main", Self.extUUID])
        #expect(displays[0].monitorUUIDs == Self.mainOrder)
        #expect(displays[1].monitorUUIDs == Self.extOrder)
        #expect(displays[0].monitorIndex == 0)
        #expect(displays[1].monitorIndex == 1)
    }

    @Test func parseCountsStaleMonitorsEntries() {
        let inspection = SpaceOrderFile.inspect(Self.config())
        #expect(inspection.monitorEntryCount == 4)
        #expect(inspection.staleMonitorCount == 2)
        #expect(inspection.layout.isUsable)
        #expect(inspection.layout.monitorsPath == ["SpacesDisplayConfiguration", "Management Data", "Monitors"])
        #expect(inspection.layout.orderingPath
                == ["SpacesDisplayConfiguration", "Management Data", "SpaceAssignments", "ManagedSpaceOrdering"])
    }

    @Test func parseReadsSpaceDetails() throws {
        let main = try #require(Self.display("Main", in: Self.config()))
        #expect(main.spaces[0] == StoredSpace(uuid: Self.chrome, id: 37, type: 4, ownerName: "Google Chrome"))
        #expect(main.spaces[2] == StoredSpace(uuid: "", id: 1, type: 0, ownerName: nil))
        #expect(main.spaces[0].isFullScreen)
        #expect(main.spaces[2].isDesktop)
    }

    @Test func parseMatchesMainToItsRealUUIDEntryByItsSpaceList() throws {
        let main = try #require(Self.display("Main", in: Self.config()))
        #expect(main.orderingDisplayID == Self.mainUUID)
        #expect(main.orderingIndex == 0)
        #expect(main.orderingNote != nil)
        // The ordering entry also lists a Space that lives on the other display.
        #expect(main.orderingUUIDs == Self.mainOrder + [Self.code1])
        #expect(main.staleOrderingUUIDs == [Self.code1])
        #expect(main.orderingLiveUUIDs == Self.mainOrder)
        #expect(main.isConsistent == true)
    }

    @Test func parseMatchesTheOrderingEntryWithTheSameIdentifier() throws {
        let ext = try #require(Self.display(Self.extUUID, in: Self.config()))
        #expect(ext.orderingDisplayID == Self.extUUID)
        #expect(ext.orderingIndex == 2)
        #expect(ext.orderingNote == nil)
        #expect(ext.staleOrderingUUIDs == ["", Self.chrome, Self.arc, Self.claude])
        #expect(ext.isConsistent == true)
    }

    @Test func parseFlagsAnOrderingEntryThatDisagrees() throws {
        var config = Self.config()
        var inner = config["SpacesDisplayConfiguration"] as! [String: Any]
        var management = inner["Management Data"] as! [String: Any]
        var assignments = management["SpaceAssignments"] as! [String: Any]
        var entries = assignments["ManagedSpaceOrdering"] as! [[String: Any]]
        entries[0]["ManagedSpaceIDs"] = [Self.telegram, Self.chrome, "", Self.arc, Self.claude]
        assignments["ManagedSpaceOrdering"] = entries
        management["SpaceAssignments"] = assignments
        inner["Management Data"] = management
        config["SpacesDisplayConfiguration"] = inner

        let main = try #require(Self.display("Main", in: config))
        #expect(main.isConsistent == false)
    }

    @Test func parseFindsTheFlatShape() throws {
        let inspection = SpaceOrderFile.inspect(Self.config(.flat))
        #expect(inspection.layout.isUsable)
        #expect(inspection.layout.monitorsPath == ["SpacesDisplayConfiguration", "Monitors"])
        #expect(inspection.layout.orderingPath
                == ["SpacesDisplayConfiguration", "SpaceAssignments", "ManagedSpaceOrdering"])
        #expect(inspection.displays.map(\.monitorUUIDs) == [Self.mainOrder, Self.extOrder])
    }

    @Test func parseAcceptsTheInnerDictionaryWithoutTheRootKey() throws {
        let inner = Self.config()["SpacesDisplayConfiguration"] as! [String: Any]
        let displays = SpaceOrderFile.parseStoredOrder(inner)
        #expect(displays.map(\.displayIdentifier) == ["Main", Self.extUUID])
    }

    @Test func parseReturnsNothingForUnknownShapes() {
        #expect(SpaceOrderFile.parseStoredOrder([:]).isEmpty)
        #expect(SpaceOrderFile.parseStoredOrder(["something": 1]).isEmpty)
        #expect(SpaceOrderFile.parseStoredOrder(["SpacesDisplayConfiguration": ["Other": 1]]).isEmpty)
        #expect(SpaceOrderFile.parseStoredOrder(Self.config(.noMonitors)).isEmpty)
        #expect(SpaceOrderFile.parseStoredOrder(Self.config(.monitorsTwice)).isEmpty)
        #expect(!SpaceOrderFile.inspect(Self.config(.monitorsTwice)).layout.isUsable)
    }

    @Test func parseWithoutOrderingStillReadsMonitors() throws {
        let inspection = SpaceOrderFile.inspect(Self.config(.noOrdering))
        #expect(!inspection.layout.isUsable)
        #expect(inspection.displays.map(\.monitorUUIDs) == [Self.mainOrder, Self.extOrder])
        #expect(inspection.displays[0].orderingIndex == nil)
        #expect(inspection.displays[0].isConsistent == nil)
    }

    @Test func parseDoesNotGuessWhenTwoOrderingEntriesFitEqually() throws {
        var config = Self.config()
        var inner = config["SpacesDisplayConfiguration"] as! [String: Any]
        var management = inner["Management Data"] as! [String: Any]
        var assignments = management["SpaceAssignments"] as! [String: Any]
        assignments["ManagedSpaceOrdering"] = [
            ["ManagedDisplayID": "AAAA", "ManagedSpaceIDs": Self.mainOrder],
            ["ManagedDisplayID": "BBBB", "ManagedSpaceIDs": Self.mainOrder],
            ["ManagedDisplayID": Self.extUUID, "ManagedSpaceIDs": Self.extOrder],
        ] as [[String: Any]]
        management["SpaceAssignments"] = assignments
        inner["Management Data"] = management
        config["SpacesDisplayConfiguration"] = inner

        let main = try #require(Self.display("Main", in: config))
        #expect(main.orderingIndex == nil)
        #expect(main.orderingNote?.contains("equally well") == true)
    }

    @Test func parseReportsASpaceWithoutAUUID() throws {
        var config = Self.config(.flat)
        var inner = config["SpacesDisplayConfiguration"] as! [String: Any]
        var monitors = inner["Monitors"] as! [[String: Any]]
        var spaces = monitors[0]["Spaces"] as! [[String: Any]]
        spaces[1].removeValue(forKey: "uuid")
        monitors[0]["Spaces"] = spaces
        inner["Monitors"] = monitors
        config["SpacesDisplayConfiguration"] = inner

        let main = try #require(Self.display("Main", in: config))
        #expect(!main.problems.isEmpty)
    }

    // MARK: reordered: success

    @Test func reorderedChangesBothArraysConsistently() throws {
        let order = [Self.telegram, Self.chrome, "", Self.arc, Self.claude]
        let result = try SpaceOrderFile.reordered(Self.config(), displayID: "Main", newOrderUUIDs: order)

        let main = try #require(Self.display("Main", in: result))
        #expect(main.monitorUUIDs == order)
        #expect(main.orderingLiveUUIDs == order)
        #expect(main.isConsistent == true)
        #expect(main.spaces.map(\.id) == [82, 37, 1, 59, 53])
    }

    @Test func reorderedKeepsStaleUUIDsInTheirSlots() throws {
        let order = [Self.claude, Self.arc, "", Self.telegram, Self.chrome]
        let result = try SpaceOrderFile.reordered(Self.config(), displayID: "Main", newOrderUUIDs: order)

        let main = try #require(Self.display("Main", in: result))
        // The stale uuid was last in the entry and still is.
        #expect(main.orderingUUIDs == order + [Self.code1])
        #expect(main.staleOrderingUUIDs == [Self.code1])
    }

    @Test func reorderedLeavesEverythingElseAlone() throws {
        let original = Self.config()
        let order = [Self.chrome, Self.telegram, Self.arc, "", Self.claude]
        let result = try SpaceOrderFile.reordered(original, displayID: "Main", newOrderUUIDs: order)

        // Other top-level keys and the other display are identical.
        #expect(Self.same(result["spans-displays"], original["spans-displays"]))
        let before = SpaceOrderFile.inspect(original)
        let after = SpaceOrderFile.inspect(result)
        #expect(after.displays[1] == before.displays[1])
        #expect(after.monitorEntryCount == before.monitorEntryCount)
        #expect(after.staleMonitorCount == before.staleMonitorCount)

        func inner(_ config: [String: Any]) -> [String: Any] { config["SpacesDisplayConfiguration"] as! [String: Any] }
        func management(_ config: [String: Any]) -> [String: Any] { inner(config)["Management Data"] as! [String: Any] }
        #expect(Self.same(inner(result)["Space Properties"], inner(original)["Space Properties"]))
        #expect(Self.same(management(result)["Age"], management(original)["Age"]))
        #expect(Self.same(management(result)["Management Mode"], management(original)["Management Mode"]))

        // Monitors entries other than "Main" are untouched, "Current Space" included.
        let newMonitors = management(result)["Monitors"] as! [[String: Any]]
        let oldMonitors = management(original)["Monitors"] as! [[String: Any]]
        #expect(Self.same(Array(newMonitors.dropFirst()), Array(oldMonitors.dropFirst())))
        #expect(Self.same(newMonitors[0]["Current Space"], oldMonitors[0]["Current Space"]))
        #expect(Self.same(newMonitors[0]["Display Identifier"], oldMonitors[0]["Display Identifier"]))

        // Ordering entries other than the matched one, and the assignments, are untouched.
        let newOrdering = (management(result)["SpaceAssignments"] as! [String: Any])["ManagedSpaceOrdering"] as! [[String: Any]]
        let oldOrdering = (management(original)["SpaceAssignments"] as! [String: Any])["ManagedSpaceOrdering"] as! [[String: Any]]
        #expect(Self.same(Array(newOrdering.dropFirst()), Array(oldOrdering.dropFirst())))
        #expect(Self.same((management(result)["SpaceAssignments"] as! [String: Any])["ManagedSpaceAssignments"],
                          (management(original)["SpaceAssignments"] as! [String: Any])["ManagedSpaceAssignments"]))
    }

    @Test func reorderedKeepsEachSpaceDictionaryIntact() throws {
        let original = Self.config()
        let order = [Self.claude, Self.arc, "", Self.telegram, Self.chrome]
        let result = try SpaceOrderFile.reordered(original, displayID: "Main", newOrderUUIDs: order)

        func spaces(_ config: [String: Any]) -> [[String: Any]] {
            let management = (config["SpacesDisplayConfiguration"] as! [String: Any])["Management Data"] as! [String: Any]
            return ((management["Monitors"] as! [[String: Any]])[0])["Spaces"] as! [[String: Any]]
        }
        let oldByUUID = Dictionary(uniqueKeysWithValues: spaces(original).map { ($0["uuid"] as! String, $0) })
        for space in spaces(result) {
            #expect(Self.same(space, oldByUUID[space["uuid"] as! String]))
        }
    }

    @Test func reorderedWithTheCurrentOrderChangesNothing() throws {
        let original = Self.config()
        let result = try SpaceOrderFile.reordered(original, displayID: "Main", newOrderUUIDs: Self.mainOrder)
        #expect(Self.same(result, original))
    }

    @Test func reorderedWorksForTheOtherDisplayAndTheFlatShape() throws {
        let order = [Self.extDesktop, Self.code1, Self.code2]
        let result = try SpaceOrderFile.reordered(Self.config(.flat), displayID: Self.extUUID, newOrderUUIDs: order)
        let ext = try #require(Self.display(Self.extUUID, in: result))
        #expect(ext.monitorUUIDs == order)
        #expect(ext.orderingUUIDs == ["", Self.chrome, Self.arc, Self.claude] + order)
        #expect(Self.display("Main", in: result)?.monitorUUIDs == Self.mainOrder)
    }

    @Test func reorderedMatchesTheDisplayIdentifierIgnoringCase() throws {
        let order = [Self.telegram, Self.chrome, "", Self.arc, Self.claude]
        let result = try SpaceOrderFile.reordered(Self.config(), displayID: "main", newOrderUUIDs: order)
        #expect(Self.display("Main", in: result)?.monitorUUIDs == order)
    }

    @Test func reorderedCanPutAFullScreenSpaceLeftOfDesktopOne() throws {
        // Start with the Desktop first on the external display, then move a full-screen Space in front of it.
        let desktopFirst = [Self.extDesktop, Self.code1, Self.code2]
        let step1 = try SpaceOrderFile.reordered(Self.config(), displayID: Self.extUUID, newOrderUUIDs: desktopFirst)
        let fullScreenFirst = [Self.code2, Self.extDesktop, Self.code1]
        let step2 = try SpaceOrderFile.reordered(step1, displayID: Self.extUUID, newOrderUUIDs: fullScreenFirst)

        let ext = try #require(Self.display(Self.extUUID, in: step2))
        #expect(ext.spaces.first?.isFullScreen == true)
        #expect(ext.spaces.map(\.uuid) == fullScreenFirst)
        #expect(ext.isConsistent == true)
    }

    @Test func reorderedOutputIsAValidPropertyListWithTypesPreserved() throws {
        let order = [Self.telegram, Self.chrome, "", Self.arc, Self.claude]
        let result = try SpaceOrderFile.reordered(Self.config(), displayID: "Main", newOrderUUIDs: order)

        let data = try PropertyListSerialization.data(fromPropertyList: result, format: .xml, options: 0)
        let back = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        #expect(Self.same(back, result))

        // Booleans stay booleans and reals stay reals.
        let flag = try #require(back["spans-displays"] as? NSNumber)
        #expect(CFGetTypeID(flag) == CFBooleanGetTypeID())
        let management = (back["SpacesDisplayConfiguration"] as! [String: Any])["Management Data"] as! [String: Any]
        let age = try #require(management["Age"] as? NSNumber)
        #expect(CFNumberIsFloatType(age))
        let mode = try #require(management["Management Mode"] as? NSNumber)
        #expect(!CFNumberIsFloatType(mode))
        #expect(mode.intValue == 1)
    }

    // MARK: reordered: refusals

    @Test func reorderedRefusesUnknownShapes() {
        let order = Self.mainOrder
        #expect(Self.isUnexpectedShape(Self.error { try SpaceOrderFile.reordered([:], displayID: "Main", newOrderUUIDs: order) }))
        #expect(Self.isUnexpectedShape(Self.error { try SpaceOrderFile.reordered(["x": 1], displayID: "Main", newOrderUUIDs: order) }))
        #expect(Self.isUnexpectedShape(Self.error {
            try SpaceOrderFile.reordered(Self.config(.monitorsTwice), displayID: "Main", newOrderUUIDs: order)
        }))
        #expect(Self.isUnexpectedShape(Self.error {
            try SpaceOrderFile.reordered(Self.config(.noOrdering), displayID: "Main", newOrderUUIDs: order)
        }))
        #expect(Self.isUnexpectedShape(Self.error {
            try SpaceOrderFile.reordered(Self.config(.noMonitors), displayID: "Main", newOrderUUIDs: order)
        }))
    }

    @Test func reorderedRefusesWhenTheMonitorsValueIsNotAnArray() {
        let config: [String: Any] = ["SpacesDisplayConfiguration": ["Management Data": ["Monitors": "oops"]]]
        #expect(Self.isUnexpectedShape(Self.error {
            try SpaceOrderFile.reordered(config, displayID: "Main", newOrderUUIDs: Self.mainOrder)
        }))
    }

    @Test func reorderedRefusesASetThatDiffers() {
        let config = Self.config()
        // One Space missing.
        let missing = Self.error { try SpaceOrderFile.reordered(config, displayID: "Main", newOrderUUIDs: Array(Self.mainOrder.dropLast())) }
        #expect(Self.isSetMismatch(missing))
        // One Space too many (from another display).
        let extra = Self.error { try SpaceOrderFile.reordered(config, displayID: "Main", newOrderUUIDs: Self.mainOrder + [Self.code1]) }
        #expect(Self.isSetMismatch(extra))
        // One Space replaced by an unknown uuid.
        let unknown = Self.error {
            try SpaceOrderFile.reordered(config, displayID: "Main", newOrderUUIDs: Array(Self.mainOrder.dropLast()) + ["NOPE"])
        }
        #expect(Self.isSetMismatch(unknown))
        // Same count, but one uuid twice.
        let twice = Self.error {
            try SpaceOrderFile.reordered(config, displayID: "Main", newOrderUUIDs: [Self.chrome, Self.chrome, "", Self.arc, Self.claude])
        }
        #expect(Self.isSetMismatch(twice))
        // Empty.
        #expect(Self.isSetMismatch(Self.error { try SpaceOrderFile.reordered(config, displayID: "Main", newOrderUUIDs: []) }))
    }

    @Test func reorderedRefusesAnUnknownDisplay() {
        let error = Self.error { try SpaceOrderFile.reordered(Self.config(), displayID: "NOPE", newOrderUUIDs: Self.mainOrder) }
        if case .displayNotFound? = error {} else { Issue.record("expected displayNotFound, got \(String(describing: error))") }
        // A stale Monitors entry without Spaces is not a display that can be reordered.
        let stale = Self.error {
            try SpaceOrderFile.reordered(Self.config(), displayID: "F9807639-7070-4BB1-8BA4-11AF2E8F9052", newOrderUUIDs: [])
        }
        if case .displayNotFound? = stale {} else { Issue.record("expected displayNotFound, got \(String(describing: stale))") }
    }

    @Test func reorderedRefusesTwoDisplaysWithTheSameIdentifier() {
        var config = Self.config(.flat)
        var inner = config["SpacesDisplayConfiguration"] as! [String: Any]
        var monitors = inner["Monitors"] as! [[String: Any]]
        monitors.append(["Display Identifier": "Main", "Spaces": [Self.space("ZZZ", id: 9, type: 0)]])
        inner["Monitors"] = monitors
        config["SpacesDisplayConfiguration"] = inner

        let error = Self.error { try SpaceOrderFile.reordered(config, displayID: "Main", newOrderUUIDs: Self.mainOrder) }
        if case .ambiguousDisplay? = error {} else { Issue.record("expected ambiguousDisplay, got \(String(describing: error))") }
    }

    @Test func reorderedRefusesWhenNoOrderingEntryHoldsTheSpaces() {
        var config = Self.config()
        var inner = config["SpacesDisplayConfiguration"] as! [String: Any]
        var management = inner["Management Data"] as! [String: Any]
        var assignments = management["SpaceAssignments"] as! [String: Any]
        // The only entry that listed Main's Spaces now lacks one of them.
        assignments["ManagedSpaceOrdering"] = [
            ["ManagedDisplayID": Self.mainUUID, "ManagedSpaceIDs": [Self.chrome, Self.telegram, "", Self.arc]],
            ["ManagedDisplayID": Self.extUUID, "ManagedSpaceIDs": Self.extOrder],
        ] as [[String: Any]]
        management["SpaceAssignments"] = assignments
        inner["Management Data"] = management
        config["SpacesDisplayConfiguration"] = inner

        let error = Self.error { try SpaceOrderFile.reordered(config, displayID: "Main", newOrderUUIDs: Self.mainOrder) }
        if case .orderingNotMatched? = error {} else { Issue.record("expected orderingNotMatched, got \(String(describing: error))") }
    }

    @Test func reorderedRefusesWhenAnOrderingEntryListsASpaceTwice() {
        var config = Self.config()
        var inner = config["SpacesDisplayConfiguration"] as! [String: Any]
        var management = inner["Management Data"] as! [String: Any]
        var assignments = management["SpaceAssignments"] as! [String: Any]
        assignments["ManagedSpaceOrdering"] = [
            ["ManagedDisplayID": Self.mainUUID, "ManagedSpaceIDs": Self.mainOrder + [Self.chrome]],
            ["ManagedDisplayID": Self.extUUID, "ManagedSpaceIDs": Self.extOrder],
        ] as [[String: Any]]
        management["SpaceAssignments"] = assignments
        inner["Management Data"] = management
        config["SpacesDisplayConfiguration"] = inner

        let error = Self.error { try SpaceOrderFile.reordered(config, displayID: "Main", newOrderUUIDs: Self.mainOrder) }
        if case .orderingNotMatched? = error {} else { Issue.record("expected orderingNotMatched, got \(String(describing: error))") }
    }

    @Test func reorderedRefusesASpaceWithoutAUUID() {
        var config = Self.config(.flat)
        var inner = config["SpacesDisplayConfiguration"] as! [String: Any]
        var monitors = inner["Monitors"] as! [[String: Any]]
        var spaces = monitors[0]["Spaces"] as! [[String: Any]]
        spaces[3].removeValue(forKey: "uuid")
        monitors[0]["Spaces"] = spaces
        inner["Monitors"] = monitors
        config["SpacesDisplayConfiguration"] = inner

        #expect(Self.isUnexpectedShape(Self.error {
            try SpaceOrderFile.reordered(config, displayID: "Main", newOrderUUIDs: Self.mainOrder)
        }))
    }

    @Test func refusalsLeaveTheInputUntouched() {
        let original = Self.config()
        let copy = Self.config()
        _ = Self.error { try SpaceOrderFile.reordered(original, displayID: "Main", newOrderUUIDs: ["nope"]) }
        #expect(Self.same(original, copy))
    }

    // MARK: Small pure helpers

    @Test func rawCopyNameBelongsToTheExportFile() {
        let export = URL(fileURLWithPath: "/tmp/backups/com.apple.spaces-20261025-120000.plist")
        #expect(SpaceOrderFile.rawCopyURL(forBackup: export).lastPathComponent == "com.apple.spaces-20261025-120000.raw.plist")
    }

    @Test func readBackupRejectsAFileThatIsNotAPlistDictionary() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceOrderFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let text = folder.appendingPathComponent("not-a-plist.plist")
        try Data("hello".utf8).write(to: text)
        #expect(throws: SpaceOrderFileError.self) { try SpaceOrderFile.readBackup(text) }
        #expect(throws: SpaceOrderFileError.self) { try SpaceOrderFile.readBackup(folder.appendingPathComponent("missing.plist")) }

        let good = folder.appendingPathComponent("good.plist")
        try PropertyListSerialization.data(fromPropertyList: Self.config(), format: .xml, options: 0).write(to: good)
        let read = try SpaceOrderFile.readBackup(good)
        #expect(SpaceOrderFile.parseStoredOrder(read).count == 2)
    }
}
