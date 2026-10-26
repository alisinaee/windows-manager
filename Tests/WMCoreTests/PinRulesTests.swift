import Foundation
import XCTest
@testable import WMCore

final class PinRulesTests: XCTestCase {
    private let mainUUID = "MAIN-UUID"
    private let secondUUID = "SECOND-UUID"

    /// Main display: Desktop 1 (id 101), Full Screen Chrome (id 102), Desktop 2 (id 103), Desktop 3 (id 104).
    /// Second display: Desktop 1 (id 201), Desktop 2 (id 202).
    private func fixture() -> [DisplaySpaces] {
        let main = DisplaySpaces(
            displayIdentifier: mainUUID, displayName: "Main", currentSpaceID: 101,
            spaces: [
                SpaceInfo(id: 101, uuid: "a", kind: .desktop, index: 0, isCurrent: true),
                SpaceInfo(id: 102, uuid: "b", kind: .fullscreen, index: 1, isCurrent: false,
                          fullScreenOwnerPID: 5, fullScreenWindowIDs: [9], ownerAppNames: ["Google Chrome"]),
                SpaceInfo(id: 103, uuid: "c", kind: .desktop, index: 2, isCurrent: false),
                SpaceInfo(id: 104, uuid: "d", kind: .desktop, index: 3, isCurrent: false),
            ])
        let second = DisplaySpaces(
            displayIdentifier: secondUUID, displayName: "Studio", currentSpaceID: 201,
            spaces: [
                SpaceInfo(id: 201, uuid: "e", kind: .desktop, index: 0, isCurrent: true),
                SpaceInfo(id: 202, uuid: "f", kind: .desktop, index: 1, isCurrent: false),
            ])
        return [main, second]
    }

    private func window(_ bundle: String = "com.apple.Safari", title: String? = "Start Page", id: UInt32 = 7,
                        space: UInt64? = 101) -> PinWindowInfo {
        PinWindowInfo(bundleID: bundle, title: title, windowID: id, currentSpaceID: space)
    }

    private func rule(_ bundle: String = "com.apple.Safari", title: String? = nil,
                      target: PinTarget = .desktopIndex(number: 3, displayUUID: "MAIN-UUID")) -> PinRule {
        PinRule(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, bundleID: bundle,
                titleContains: title, target: target)
    }

    // MARK: Rule matching

    func testBundleIDMatchesIgnoringCase() {
        XCTAssertTrue(rule("COM.Apple.Safari").matches(bundleID: "com.apple.safari", title: nil))
        XCTAssertFalse(rule("com.apple.Safari").matches(bundleID: "com.apple.Notes", title: nil))
    }

    func testEmptyBundleIDNeverMatches() {
        XCTAssertFalse(rule("  ").matches(bundleID: "", title: nil))
    }

    func testTitleFilterIsCaseInsensitiveSubstring() {
        let r = rule(title: "inbox")
        XCTAssertTrue(r.matches(bundleID: "com.apple.Safari", title: "Gmail - Inbox (3)"))
        XCTAssertFalse(r.matches(bundleID: "com.apple.Safari", title: "Start Page"))
    }

    func testTitleFilterDoesNotMatchUnknownTitle() {
        XCTAssertFalse(rule(title: "Inbox").matches(bundleID: "com.apple.Safari", title: nil))
    }

    func testBlankTitleFilterMeansEveryWindow() {
        XCTAssertTrue(rule(title: "   ").matches(bundleID: "com.apple.Safari", title: nil))
    }

    // MARK: Target resolution

    func testDesktopIndexCountsOnlyDesktops() {
        // Desktop 2 of the main display is id 103 (the full-screen Space 102 is not counted).
        XCTAssertEqual(PinRules.targetSpaceID(for: .desktopIndex(number: 2, displayUUID: mainUUID), in: fixture()), 103)
        XCTAssertEqual(PinRules.targetSpaceID(for: .desktopIndex(number: 1, displayUUID: secondUUID), in: fixture()), 201)
    }

    func testDesktopIndexOutOfRangeOrUnknownDisplayIsNil() {
        XCTAssertNil(PinRules.targetSpaceID(for: .desktopIndex(number: 4, displayUUID: mainUUID), in: fixture()))
        XCTAssertNil(PinRules.targetSpaceID(for: .desktopIndex(number: 0, displayUUID: mainUUID), in: fixture()))
        XCTAssertNil(PinRules.targetSpaceID(for: .desktopIndex(number: 1, displayUUID: "gone"), in: fixture()))
    }

    func testSpaceIDMustBeADesktop() {
        XCTAssertEqual(PinRules.targetSpaceID(for: .spaceID(202), in: fixture()), 202)
        XCTAssertNil(PinRules.targetSpaceID(for: .spaceID(102), in: fixture()))
        XCTAssertNil(PinRules.targetSpaceID(for: .spaceID(999), in: fixture()))
    }

    // MARK: Decisions

    func testDecidesMoveToRuleDesktop() {
        let decision = PinRules.decide(newWindow: window(), rules: [rule()], spaces: fixture())
        XCTAssertEqual(decision, PinDecision(windowID: 7, ruleID: rule().id, fromSpaceID: 101, targetSpaceID: 104))
    }

    func testNoMoveWhenAlreadyOnTarget() {
        XCTAssertNil(PinRules.decide(newWindow: window(space: 104), rules: [rule()], spaces: fixture()))
    }

    func testNoMoveWithoutMatchingRule() {
        XCTAssertNil(PinRules.decide(newWindow: window("com.apple.Notes"), rules: [rule()], spaces: fixture()))
        XCTAssertNil(PinRules.decide(newWindow: window(), rules: [], spaces: fixture()))
    }

    func testFirstMatchingRuleWins() {
        let first = PinRule(bundleID: "com.apple.Safari", target: .spaceID(202))
        let second = PinRule(bundleID: "com.apple.Safari", target: .spaceID(104))
        let decision = PinRules.decide(newWindow: window(), rules: [first, second], spaces: fixture())
        XCTAssertEqual(decision?.targetSpaceID, 202)
        XCTAssertEqual(decision?.ruleID, first.id)
    }

    func testTitleRuleOnlyMovesMatchingWindow() {
        let r = rule(title: "Inbox")
        XCTAssertNil(PinRules.decide(newWindow: window(title: "Start Page"), rules: [r], spaces: fixture()))
        XCTAssertNotNil(PinRules.decide(newWindow: window(title: "Inbox - Mail"), rules: [r], spaces: fixture()))
    }

    func testFullScreenWindowIsNeverPinned() {
        XCTAssertNil(PinRules.decide(newWindow: window(space: 102), rules: [rule()], spaces: fixture()))
    }

    func testWindowOnNoOrSeveralSpacesIsNotPinned() {
        XCTAssertNil(PinRules.decide(newWindow: window(space: nil), rules: [rule()], spaces: fixture()))
    }

    func testFullScreenTargetIsRejected() {
        let r = PinRule(bundleID: "com.apple.Safari", target: .spaceID(102))
        XCTAssertNil(PinRules.decide(newWindow: window(), rules: [r], spaces: fixture()))
    }

    func testMissingDesktopIsNotPinned() {
        let r = rule(target: .desktopIndex(number: 9, displayUUID: mainUUID))
        XCTAssertNil(PinRules.decide(newWindow: window(), rules: [r], spaces: fixture()))
    }

    func testWindowIsMovedAtMostOnce() {
        var history = PinHistory(now: Date(timeIntervalSince1970: 1000))
        history.alreadyMoved = [7]
        XCTAssertNil(PinRules.decide(newWindow: window(), rules: [rule()], spaces: fixture(), history: history))
    }

    func testManualMoveWithinQuietPeriodBlocksPin() {
        let base = Date(timeIntervalSince1970: 1000)
        var history = PinHistory(now: base.addingTimeInterval(4), manualQuietPeriod: 10,
                                 manualMoveTimes: [7: base])
        XCTAssertTrue(history.isInQuietPeriod(7))
        XCTAssertNil(PinRules.decide(newWindow: window(), rules: [rule()], spaces: fixture(), history: history))

        history.now = base.addingTimeInterval(10)
        XCTAssertFalse(history.isInQuietPeriod(7))
        XCTAssertNotNil(PinRules.decide(newWindow: window(), rules: [rule()], spaces: fixture(), history: history))
    }

    func testManualMoveOfAnotherWindowDoesNotBlock() {
        let history = PinHistory(now: Date(timeIntervalSince1970: 1000), manualMoveTimes: [8: Date(timeIntervalSince1970: 999)])
        XCTAssertNotNil(PinRules.decide(newWindow: window(), rules: [rule()], spaces: fixture(), history: history))
    }

    // MARK: Codable and store

    func testTargetRoundTrips() throws {
        let targets: [PinTarget] = [.desktopIndex(number: 2, displayUUID: "U"), .spaceID(77)]
        for target in targets {
            let data = try JSONEncoder().encode(target)
            XCTAssertEqual(try JSONDecoder().decode(PinTarget.self, from: data), target)
        }
    }

    func testUnknownTargetTypeFailsToDecode() {
        let json = Data(#"{"type":"nowhere"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PinTarget.self, from: json))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PinRulesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testStoreRoundTripsRules() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PinRulesStore(directory: dir)
        let rules = [rule(), PinRule(bundleID: "com.apple.Notes", titleContains: "Todo", target: .spaceID(202))]
        try store.save(rules)
        XCTAssertEqual(PinRulesStore(directory: dir).load(), rules)
        XCTAssertEqual(store.file.lastPathComponent, "PinRules.json")
    }

    func testMissingOrCorruptFileReadsAsNoRules() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PinRulesStore(directory: dir)
        XCTAssertEqual(store.load(), [])
        try Data("not json".utf8).write(to: store.file)
        XCTAssertEqual(store.load(), [])
    }
}
