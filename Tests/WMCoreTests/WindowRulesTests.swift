import XCTest
@testable import WMCore

final class WindowRulesTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wr-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("WindowRules.json")
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertTrue(WindowRulesStore(file: tempFile()).load().rules.isEmpty)
    }

    func testRoundTripAllActions() throws {
        let store = WindowRulesStore(file: tempFile())
        var rules = WindowRules()
        rules.set(WindowRule(bundleID: "com.a", action: .ignore))
        rules.set(WindowRule(bundleID: "com.b", action: .alwaysRestore))
        rules.set(WindowRule(bundleID: "com.c", action: .pinToDisplay(uuid: "UUID-1")))
        try store.save(rules)
        XCTAssertEqual(store.load(), rules)
    }

    func testSetReplacesIgnoringCaseAndRemove() {
        var rules = WindowRules()
        rules.set(WindowRule(bundleID: "com.A", action: .ignore))
        rules.set(WindowRule(bundleID: "com.a", action: .alwaysRestore))
        XCTAssertEqual(rules.rules.count, 1)
        XCTAssertEqual(rules.rule(for: "COM.A")?.action, .alwaysRestore)
        rules.remove(bundleID: "com.a")
        XCTAssertTrue(rules.rules.isEmpty)
    }

    func testEmptyBundleIDIgnored() {
        var rules = WindowRules()
        rules.set(WindowRule(bundleID: "  ", action: .ignore))
        XCTAssertTrue(rules.rules.isEmpty)
    }

    func testCorruptFileLoadsEmpty() throws {
        let file = tempFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: file)
        XCTAssertTrue(WindowRulesStore(file: file).load().rules.isEmpty)
    }

    func testUnknownActionFailsDecode() {
        let json = Data(#"{"schemaVersion":1,"rules":[{"bundleID":"x","action":{"type":"boom"}}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WindowRules.self, from: json))
    }
}
