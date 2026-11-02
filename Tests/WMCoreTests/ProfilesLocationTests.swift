import Foundation
import Testing
import XCTest
@testable import WMCore

struct ProfilesLocationTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wm-loc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let fallback = URL(fileURLWithPath: "/tmp/wm-default-fallback", isDirectory: true)

    @Test func resolutionOrder() {
        #expect(ProfilesLocation.resolve(environment: [:], preference: nil, fallback: fallback) == fallback)
        #expect(ProfilesLocation.resolve(environment: [:], preference: "  ", fallback: fallback) == fallback)
        #expect(ProfilesLocation.resolve(environment: [:], preference: "/tmp/chosen", fallback: fallback).path == "/tmp/chosen")
        let env = ["WM_PROFILES_DIR": "/tmp/env"]
        #expect(ProfilesLocation.resolve(environment: env, preference: "/tmp/chosen", fallback: fallback).path == "/tmp/env")
    }

    @Test func migrationNeverOverwritesOrDeletes() throws {
        let old = try tempDir(), new = try tempDir()
        defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: new) }
        try "old-a".write(to: old.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)
        try "old-b".write(to: old.appendingPathComponent("b.json"), atomically: true, encoding: .utf8)
        try "note".write(to: old.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "new-a".write(to: new.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)

        let copied = try ProfilesLocation.migrate(from: old, to: new)
        #expect(copied == 1)
        #expect(try String(contentsOf: new.appendingPathComponent("a.json"), encoding: .utf8) == "new-a")
        #expect(try String(contentsOf: new.appendingPathComponent("b.json"), encoding: .utf8) == "old-b")
        #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("notes.txt").path))
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("a.json").path))
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("b.json").path))
    }

    @Test func scanIgnoresICloudPlaceholdersAndConflictCopies() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(folder: dir)
        let saved = try store.save(Profile(name: "Work", monitorSetKey: "k"))
        let id = saved.id.uuidString
        try Data().write(to: dir.appendingPathComponent(".\(UUID().uuidString).json.icloud"))
        try FileManager.default.copyItem(at: store.fileURL(for: saved.id), to: dir.appendingPathComponent("\(id) 2.json"))

        let listing = store.scan()
        #expect(listing.summaries.map(\.name) == ["Work"])
        #expect(listing.problems.isEmpty)
        #expect(listing.placeholders.count == 1)
        #expect(listing.conflicts.count == 1)
    }

    @Test func storeSwitchesFolder() throws {
        let a = try tempDir(), b = try tempDir()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let store = ProfileStore(folder: a)
        _ = try store.save(Profile(name: "One", monitorSetKey: "k"))
        store.switchFolder(to: b)
        #expect(store.list().isEmpty)
        #expect(store.folder == b)
    }
}

final class ProfileFolderWatcherTests: XCTestCase {
    func testFiresWhenJsonIsRewrittenInPlace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wm-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("profile.json")
        try Data("{\"v\":1}".utf8).write(to: file)

        let changed = expectation(description: "onChange after in-place rewrite")
        changed.assertForOverFulfill = false
        let watcher = ProfileFolderWatcher(debounce: 0.2) { changed.fulfill() }
        watcher.start(folder: dir)
        defer { watcher.stop() }

        // Overwrite the same inode (no rename, no new entry), so only the poll can see it.
        try Data("{\"v\":2,\"name\":\"rewritten with more bytes\"}".utf8).write(to: file)
        wait(for: [changed], timeout: 5)
    }
}
