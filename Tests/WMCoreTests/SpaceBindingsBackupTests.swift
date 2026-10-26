import Foundation
import XCTest
@testable import WMCore

final class SpaceBindingsBackupTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpaceBindingsBackupTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fakes

    /// Records every command. Never runs anything. For `defaults import`, keeps the plist contents it was given.
    private final class FakeRunner: CommandRunning {
        var calls: [(path: String, arguments: [String])] = []
        var imported: [String: [String: Any]] = [:]
        var status: Int32 = 0

        func run(_ path: String, arguments: [String]) throws -> CommandResult {
            calls.append((path, arguments))
            if path == "/usr/bin/defaults", arguments.count == 3, arguments[0] == "import" {
                let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
                imported[arguments[1]] = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    as? [String: Any]
            }
            return CommandResult(status: status, stderr: status == 0 ? "" : "boom")
        }

        var commandLines: [String] { calls.map { ([$0.path] + $0.arguments).joined(separator: " ") } }
    }

    private final class FakePreferences {
        var domains: [String: [String: Any]]

        init(domains: [String: [String: Any]]) { self.domains = domains }

        func read(_ domain: String) -> [String: Any] { domains[domain] ?? [:] }
    }

    /// Each call returns a time one minute after the previous one, so backup names never collide.
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)

        func next() -> Date {
            defer { now = now.addingTimeInterval(60) }
            return now
        }
    }

    private func bindings(_ ids: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        for id in ids { result[id] = ["enabled": true, "value": id] }
        return result
    }

    private func fixturePreferences() -> FakePreferences {
        FakePreferences(domains: [
            SpaceBindingsBackup.spacesDomain: [
                SpaceBindingsBackup.spacesRootKey: ["Management Data": ["Monitors": ["live": true]]],
                "Other": "kept",
            ],
            SpaceBindingsBackup.hotkeysDomain: [
                SpaceBindingsBackup.hotkeysRootKey: bindings(["79", "80", "118", "7", "60"]),
            ],
        ])
    }

    private func makeBackup(_ prefs: FakePreferences, runner: FakeRunner = FakeRunner(),
                            clock: TestClock = TestClock()) -> SpaceBindingsBackup {
        SpaceBindingsBackup(folder: folder, reader: prefs.read, runner: runner, clock: clock.next)
    }

    private func backupFileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: Backup

    func testBackupWritesOneFileWithSpacesAndWantedHotkeysOnly() throws {
        let backup = makeBackup(fixturePreferences())

        let info = try backup.backupNow(reason: "Before Login Test!")

        XCTAssertEqual(info.reason, "before-login-test")
        XCTAssertEqual(info.url.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertTrue(info.url.lastPathComponent.hasSuffix("-before-login-test.plist"))
        let data = try Data(contentsOf: info.url)
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                                 as? [String: Any])
        XCTAssertEqual(root["format"] as? Int, 1)
        let domains = try XCTUnwrap(root["domains"] as? [String: Any])
        let spaces = try XCTUnwrap(domains[SpaceBindingsBackup.spacesDomain] as? [String: Any])
        XCTAssertNotNil(spaces[SpaceBindingsBackup.spacesRootKey])
        XCTAssertEqual(spaces["Other"] as? String, "kept")
        let hotkeys = try XCTUnwrap(domains[SpaceBindingsBackup.hotkeysDomain] as? [String: Any])
        let kept = try XCTUnwrap(hotkeys[SpaceBindingsBackup.hotkeysRootKey] as? [String: Any])
        XCTAssertEqual(Set(kept.keys), ["79", "80", "118"], "only the Mission Control ids are saved")
    }

    func testBackupFolderKeepsNewest20AndNeverDeletesOtherFiles() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "notes".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "{}".write(to: folder.appendingPathComponent("last-known-good.json"), atomically: true, encoding: .utf8)
        let clock = TestClock()
        let backup = makeBackup(fixturePreferences(), clock: clock)

        var written: [BackupInfo] = []
        for index in 0..<22 {
            written.append(try backup.backupNow(reason: "auto \(index)"))
        }

        let listed = backup.list()
        XCTAssertEqual(listed.count, 20)
        XCTAssertEqual(listed.first?.url.lastPathComponent, written.last?.url.lastPathComponent, "newest first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: written[0].url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: written[1].url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: written[2].url.path))
        XCTAssertTrue(backupFileNames().contains("notes.txt"))
        XCTAssertTrue(backupFileNames().contains("last-known-good.json"))
    }

    func testBackupFailsWhenSpacesDomainIsMissingAndWritesNothing() {
        let prefs = FakePreferences(domains: [SpaceBindingsBackup.hotkeysDomain: [
            SpaceBindingsBackup.hotkeysRootKey: bindings(["79"]),
        ]])
        let backup = makeBackup(prefs)

        XCTAssertThrowsError(try backup.backupNow(reason: "x")) { error in
            guard case SpaceBindingsBackupError.backupFailed = error else {
                return XCTFail("wrong error \(error)")
            }
        }
        XCTAssertTrue(backup.list().isEmpty)
    }

    // MARK: Restore

    func testRestoreRefusesWithoutConfirmation() throws {
        let runner = FakeRunner()
        let backup = makeBackup(fixturePreferences(), runner: runner)
        let info = try backup.backupNow(reason: "manual")

        XCTAssertThrowsError(try backup.restore(info, confirmed: false)) { error in
            XCTAssertEqual(error as? SpaceBindingsBackupError, .notConfirmed)
        }
        XCTAssertTrue(runner.calls.isEmpty, "nothing may run without confirmation")
    }

    func testRestoreWithConfirmationImportsBothDomainsThenRestartsDockOnce() throws {
        let runner = FakeRunner()
        let prefs = fixturePreferences()
        let backup = makeBackup(prefs, runner: runner)
        let info = try backup.backupNow(reason: "manual")

        // The live hotkeys change after the backup: 120 is new (not in the backup), 7 and 60 are not Mission Control ids.
        prefs.domains[SpaceBindingsBackup.hotkeysDomain] = [
            SpaceBindingsBackup.hotkeysRootKey: bindings(["79", "118", "7", "60", "120"]),
        ]
        runner.calls = []

        try backup.restore(info, confirmed: true)

        XCTAssertEqual(runner.commandLines, [
            "/usr/bin/defaults import com.apple.spaces \(runner.calls[0].arguments[2])",
            "/usr/bin/defaults import com.apple.symbolichotkeys \(runner.calls[1].arguments[2])",
            "/usr/bin/killall Dock",
        ])
        XCTAssertEqual(runner.calls.filter { $0.path == "/usr/bin/killall" }.count, 1)

        let importedSpaces = try XCTUnwrap(runner.imported[SpaceBindingsBackup.spacesDomain])
        XCTAssertEqual(importedSpaces["Other"] as? String, "kept")

        let importedHotkeys = try XCTUnwrap(runner.imported[SpaceBindingsBackup.hotkeysDomain])
        let merged = try XCTUnwrap(importedHotkeys[SpaceBindingsBackup.hotkeysRootKey] as? [String: Any])
        XCTAssertEqual(Set(merged.keys), ["79", "80", "118", "7", "60"],
                       "saved ids come back, ids outside the backup set are kept, 120 (not in the backup) is removed")
        let restored118 = try XCTUnwrap(merged["118"] as? [String: Any])
        XCTAssertEqual(restored118["value"] as? String, "118")
    }

    func testRestoreWithKillDockFalseSkipsTheDockRestart() throws {
        let runner = FakeRunner()
        let backup = makeBackup(fixturePreferences(), runner: runner)
        let info = try backup.backupNow(reason: "manual")
        runner.calls = []

        try backup.restore(info, confirmed: true, killDock: false)

        XCTAssertEqual(runner.calls.map(\.path), ["/usr/bin/defaults", "/usr/bin/defaults"])
    }

    func testRestoreStopsWhenDefaultsImportFails() throws {
        let runner = FakeRunner()
        let backup = makeBackup(fixturePreferences(), runner: runner)
        let info = try backup.backupNow(reason: "manual")
        runner.calls = []
        runner.status = 1

        XCTAssertThrowsError(try backup.restore(info, confirmed: true))
        XCTAssertEqual(runner.calls.count, 1, "no second import and no Dock restart after a failure")
    }

    func testRestoreRejectsAFileThatIsNotABackup() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bogus = folder.appendingPathComponent("20260101-000000-000-bogus.plist")
        let wrong: [String: Any] = ["format": 1, "domains": ["com.apple.spaces": ["Other": 1]]]
        try PropertyListSerialization.data(fromPropertyList: wrong, format: .xml, options: 0).write(to: bogus)
        let runner = FakeRunner()
        let backup = makeBackup(fixturePreferences(), runner: runner)
        let info = try XCTUnwrap(backup.list().first)

        XCTAssertThrowsError(try backup.restore(info, confirmed: true)) { error in
            guard case SpaceBindingsBackupError.invalidBackup = error else {
                return XCTFail("wrong error \(error)")
            }
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    // MARK: Login repair

    private func order(_ keys: [String], display: String = "MAIN") -> DisplaySpaceOrder {
        DisplaySpaceOrder(displayID: display, name: nil,
                          slots: keys.map { SpaceSlot(key: $0, label: $0) })
    }

    private func snapshot(_ keys: [String], takenAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
                          backup: BackupInfo? = nil) -> SpaceOrderSnapshot {
        SpaceOrderSnapshot(displays: [order(keys)], takenAt: takenAt, backup: backup)
    }

    private let goodBackup = BackupInfo(
        url: URL(fileURLWithPath: "/x/20260101-120000-000-manual.plist"),
        date: Date(timeIntervalSince1970: 1_800_000_100), reason: "manual")

    func testAssessWithoutBaselineReportsNoBaseline() {
        let advice = LoginRepair.assess(lastKnownGood: nil, current: snapshot(["desktop:1"]))

        XCTAssertEqual(advice.kind, .noBaseline)
        XCTAssertNil(advice.suggestedBackup)
        XCTAssertFalse(advice.sentence.isEmpty)
    }

    func testAssessSameOrderIsFine() {
        let good = snapshot(["desktop:1", "desktop:2", "fullscreen:Safari"], backup: goodBackup)
        let advice = LoginRepair.assess(lastKnownGood: good, current: snapshot(["desktop:1", "desktop:2", "fullscreen:Safari"]))

        XCTAssertEqual(advice.kind, .fine)
        XCTAssertEqual(advice.suggestedBackup, goodBackup)
    }

    func testAssessFewerDesktopsIsSpacesLostWithCount() {
        let good = snapshot(["desktop:1", "desktop:2", "desktop:3"], backup: goodBackup)
        let advice = LoginRepair.assess(lastKnownGood: good, current: snapshot(["desktop:1"]))

        XCTAssertEqual(advice.kind, .spacesLost(count: 2))
        XCTAssertEqual(advice.suggestedBackup, goodBackup)
        XCTAssertTrue(advice.sentence.contains("2 fewer Desktops"))
    }

    func testAssessSameDesktopsInOtherOrderIsReordered() {
        let good = snapshot(["desktop:1", "desktop:2"], backup: goodBackup)
        let advice = LoginRepair.assess(lastKnownGood: good, current: snapshot(["desktop:2", "desktop:1"]))

        XCTAssertEqual(advice.kind, .reordered)
        XCTAssertEqual(advice.suggestedBackup, goodBackup)
    }

    func testAssessIgnoresDisplaysThatAreNotInBothSnapshots() {
        let good = SpaceOrderSnapshot(displays: [order(["desktop:1"]), order(["desktop:1", "desktop:2"], display: "SECOND")],
                                 takenAt: Date(timeIntervalSince1970: 1_800_000_000))
        let current = SpaceOrderSnapshot(displays: [order(["desktop:1"])], takenAt: Date())

        XCTAssertEqual(LoginRepair.assess(lastKnownGood: good, current: current).kind, .fine)
    }

    // MARK: Snapshot store

    func testStoreSavesOnlyWhenTheGuardReportIsClean() throws {
        let store = SpaceSnapshotStore(folder: folder)
        let expected = [order(["desktop:1", "desktop:2"])]
        let clean = SpaceGuard.evaluate(expected: expected, actual: expected, mruSpaces: false)
        let drifted = SpaceGuard.evaluate(expected: expected, actual: [order(["desktop:2", "desktop:1"])], mruSpaces: false)
        let current = snapshot(["desktop:1", "desktop:2"])

        XCTAssertFalse(try store.save(current, report: drifted))
        XCTAssertNil(store.load(), "a drifted layout never becomes the last known good one")

        XCTAssertTrue(try store.save(current, report: clean))
        XCTAssertEqual(store.load(), current)
    }
}
