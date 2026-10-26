import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Tests for the profile model and its JSON store. Every store test works in its own temp folder.
@Suite struct ProfileStoreTests {
    // MARK: Fixtures

    static let samsungUUID = "5A0E2C1B-0000-4000-8000-0000000000A1"
    static let macbookUUID = "5A0E2C1B-0000-4000-8000-0000000000B2"

    static let samsung = DisplayIdentity(
        uuid: samsungUUID, name: "SAMSUNG U32R59x", vendorID: 0x4C2D, modelID: 0x0D79, serial: 0x0001_2345,
        frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
        visibleFrame: CGRect(x: 0, y: 38, width: 3840, height: 2062),
        isMain: true, isBuiltIn: false, scale: 1)
    static let macbook = DisplayIdentity(
        uuid: macbookUUID, name: "Built-in Retina Display", vendorID: 0x0610, modelID: 0xA050, serial: 0,
        frame: CGRect(x: -1512, y: 600, width: 1512, height: 982),
        visibleFrame: CGRect(x: -1512, y: 638, width: 1512, height: 944),
        isMain: false, isBuiltIn: true, scale: 2)

    /// Deterministic window ids: wid(1) ... wid(99).
    static func wid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static let t0 = Date(timeIntervalSince1970: 1_761_400_000)

    static func app(_ name: String, _ bundleID: String?) -> AppRef {
        AppRef(bundleID: bundleID, name: name, path: bundleID == nil ? nil : "/Applications/\(name).app")
    }

    /// Fractions of the display's visible frame, like a capture would compute.
    static func relative(_ frame: CGRect, in display: DisplayIdentity) -> CGRect {
        let v = display.visibleFrame
        return CGRect(x: (frame.minX - v.minX) / v.width, y: (frame.minY - v.minY) / v.height,
                      width: frame.width / v.width, height: frame.height / v.height)
    }

    static func window(_ n: Int, _ app: AppRef, on display: DisplayIdentity, frame: CGRect? = nil,
                       placement: SpacePlacement, title: String? = nil, match: TitleMatch = .any,
                       document: String? = nil, indexInApp: Int = 0, fullScreen: Bool = false,
                       minimized: Bool = false, zIndex: Int = 0, restore: Bool = true) -> WindowSnapshot {
        let rect = frame ?? display.frame
        return WindowSnapshot(id: wid(n), app: app, title: title, titleMatch: match, documentPath: document,
                              indexInApp: indexInApp, displayUUID: display.uuid, frame: rect,
                              relativeFrame: fullScreen ? CGRect(x: 0, y: 0, width: 1, height: 1) : relative(rect, in: display),
                              placement: placement, isFullScreen: fullScreen, isMinimized: minimized,
                              zIndex: zIndex, restore: restore)
    }

    /// Two displays. Samsung: [Chrome FS, Telegram FS, Desktop 1, Arc FS, Claude FS].
    /// MacBook: [VS Code FS, Safari + Notes Split View, Desktop 1].
    static func makeProfile(id: UUID = UUID(), name: String = "Work") -> Profile {
        let chrome = app("Google Chrome", "com.google.Chrome")
        let telegram = app("Telegram", "ru.keepcoder.Telegram")
        let finder = app("Finder", "com.apple.finder")
        let terminal = app("Terminal", "com.apple.Terminal")
        let arc = app("Arc", "company.thebrowser.Browser")
        let claude = app("Claude", "com.anthropic.claudefordesktop")
        let code = app("Visual Studio Code", "com.microsoft.VSCode")
        let safari = app("Safari", "com.apple.Safari")
        let notes = app("Notes", "com.apple.Notes")
        let preview = app("Preview", "com.apple.Preview")
        let stickies = app("Stickies", "com.apple.Stickies")
        let messages = app("Messages", "com.apple.MobileSMS")
        let legacy = app("Old Tool", nil)

        let windows: [WindowSnapshot] = [
            window(1, chrome, on: samsung, placement: .fullScreen(position: 0), title: "Inbox - Mail",
                   fullScreen: true, zIndex: 7),
            window(2, telegram, on: samsung, placement: .fullScreen(position: 1), title: "Telegram",
                   match: .exact("Telegram"), fullScreen: true, zIndex: 8),
            window(3, finder, on: samsung, frame: CGRect(x: 120, y: 200, width: 900, height: 600),
                   placement: .desktop(number: 1), title: "Downloads", match: .exact("Downloads"),
                   document: "/Users/ali/Downloads", indexInApp: 0, zIndex: 1),
            window(4, finder, on: samsung, frame: CGRect(x: 300, y: 260, width: 900, height: 600),
                   placement: .desktop(number: 1), title: "Documents", match: .contains("Docu"),
                   document: "/Users/ali/Documents", indexInApp: 1, zIndex: 2),
            window(5, terminal, on: samsung, frame: CGRect(x: 1400, y: 100, width: 1200, height: 800),
                   placement: .desktop(number: 1), title: "~/Works/windows_manager",
                   match: .regex("^~/Works/.+"), zIndex: 0),
            window(6, arc, on: samsung, placement: .fullScreen(position: 3), title: "Arc",
                   fullScreen: true, zIndex: 9),
            window(7, claude, on: samsung, placement: .fullScreen(position: 4), title: "Claude",
                   fullScreen: true, zIndex: 10),
            window(8, code, on: macbook, placement: .fullScreen(position: 0), title: "Profile.swift",
                   fullScreen: true, zIndex: 11),
            window(9, safari, on: macbook, frame: CGRect(x: -1512, y: 638, width: 756, height: 944),
                   placement: .fullScreen(position: 1), title: "Apple", fullScreen: true, zIndex: 12),
            window(10, notes, on: macbook, frame: CGRect(x: -756, y: 638, width: 756, height: 944),
                   placement: .fullScreen(position: 1), title: "Shopping", fullScreen: true, zIndex: 13),
            window(11, preview, on: macbook, frame: CGRect(x: -1300, y: 700, width: 600, height: 500),
                   placement: .desktop(number: 1), title: "invoice.pdf", match: .contains("invoice"),
                   document: "/Users/ali/Documents/invoice.pdf", minimized: true, zIndex: 4),
            window(12, stickies, on: macbook, frame: CGRect(x: -400, y: 700, width: 300, height: 300),
                   placement: .allDesktops, title: nil, zIndex: 3),
            window(13, messages, on: macbook, frame: CGRect(x: -1000, y: 900, width: 500, height: 400),
                   placement: .desktop(number: 1), title: "Messages", zIndex: 5, restore: false),
            window(14, legacy, on: macbook, frame: CGRect(x: -900, y: 800, width: 400, height: 300),
                   placement: .unknown, title: "Legacy", zIndex: 6),
        ]

        let spaces: [SpaceSnapshot] = [
            SpaceSnapshot(displayUUID: samsungUUID, position: 0, kind: .fullScreen, fullScreenWindowIDs: [wid(1)]),
            SpaceSnapshot(displayUUID: samsungUUID, position: 1, kind: .fullScreen, fullScreenWindowIDs: [wid(2)]),
            SpaceSnapshot(displayUUID: samsungUUID, position: 2, kind: .desktop, desktopNumber: 1),
            SpaceSnapshot(displayUUID: samsungUUID, position: 3, kind: .fullScreen, fullScreenWindowIDs: [wid(6)]),
            SpaceSnapshot(displayUUID: samsungUUID, position: 4, kind: .fullScreen, fullScreenWindowIDs: [wid(7)]),
            SpaceSnapshot(displayUUID: macbookUUID, position: 0, kind: .fullScreen, fullScreenWindowIDs: [wid(8)]),
            SpaceSnapshot(displayUUID: macbookUUID, position: 1, kind: .fullScreen,
                          fullScreenWindowIDs: [wid(9), wid(10)]),
            SpaceSnapshot(displayUUID: macbookUUID, position: 2, kind: .desktop, desktopNumber: 1),
        ]

        return Profile(id: id, name: name, icon: "briefcase", createdAt: t0, updatedAt: t0,
                       monitorSetKey: "\(macbookUUID)+\(samsungUUID)", displays: [samsung, macbook],
                       spaces: spaces, windows: windows,
                       options: ProfileOptions(launchMissingApps: true, restoreFullScreen: true,
                                               restoreSpaces: true, restoreSpaceOrder: false,
                                               otherApps: .hide, hotkey: "ctrl+opt+1"),
                       notes: "Two monitors, full-screen apps left of Desktop 1.")
    }

    /// A fresh store in its own temp folder. The profile folder itself does not exist yet.
    static func withStore(_ body: (ProfileStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Profiles", isDirectory: true)
        try body(ProfileStore(folder: folder), folder)
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func fileNames(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: Model

    @Test func fixtureHasNoProblems() {
        #expect(Self.makeProfile().validate().isEmpty)
    }

    @Test func spacesOnDisplayAreSortedByPosition() {
        var profile = Self.makeProfile()
        profile.spaces.reverse()
        let samsung = profile.spaces(onDisplay: Self.samsungUUID)
        #expect(samsung.map(\.position) == [0, 1, 2, 3, 4])
        #expect(samsung.map(\.kind) == [.fullScreen, .fullScreen, .desktop, .fullScreen, .fullScreen])
        #expect(samsung[2].desktopNumber == 1)
        let macbook = profile.spaces(onDisplay: Self.macbookUUID)
        #expect(macbook.map(\.position) == [0, 1, 2])
        #expect(macbook[1].isSplitView)
        #expect(macbook[1].fullScreenWindowIDs == [Self.wid(9), Self.wid(10)])
        #expect(!macbook[0].isSplitView)
        #expect(profile.spaces(onDisplay: "nope").isEmpty)
    }

    @Test func appsAreUniqueInFirstSeenOrder() {
        let profile = Self.makeProfile()
        #expect(profile.apps.map(\.name) == [
            "Google Chrome", "Telegram", "Finder", "Terminal", "Arc", "Claude", "Visual Studio Code",
            "Safari", "Notes", "Preview", "Stickies", "Messages", "Old Tool",
        ])
    }

    @Test func windowsForAppFollowIndexInApp() {
        var profile = Self.makeProfile()
        profile.windows.reverse()
        let finder = profile.windows(for: AppRef(bundleID: "com.apple.finder", name: "Finder"))
        #expect(finder.map(\.title) == ["Downloads", "Documents"])
        #expect(finder.map(\.indexInApp) == [0, 1])
        // An app without a bundle id is matched by name, ignoring case.
        #expect(profile.windows(for: AppRef(bundleID: nil, name: "old tool")).count == 1)
        // A different bundle id is a different app even with the same name.
        #expect(profile.windows(for: AppRef(bundleID: "com.other.Finder", name: "Finder")).isEmpty)
    }

    @Test func savedSpaceKindMapsSpaceKind() {
        #expect(SavedSpaceKind(.desktop) == .desktop)
        #expect(SavedSpaceKind(.fullscreen) == .fullScreen)
        #expect(SavedSpaceKind(.other(2)) == .other)
    }

    @Test func optionsAndWindowDefaults() {
        let options = ProfileOptions()
        #expect(options.launchMissingApps && options.restoreFullScreen && options.restoreSpaces && options.restoreSpaceOrder)
        #expect(options.otherApps == .leave)
        #expect(options.hotkey == nil)

        let window = WindowSnapshot(app: AppRef(bundleID: nil, name: "X"), displayUUID: "d", frame: .zero,
                                    relativeFrame: .zero, placement: .unknown)
        #expect(window.titleMatch == .any)
        #expect(window.restore)
        #expect(window.zIndex == 0)

        let profile = Profile(name: "P", monitorSetKey: "k")
        #expect(profile.icon == "rectangle.3.group")
        #expect(profile.schemaVersion == 1)
        #expect(profile.updatedAt == profile.createdAt)
    }

    // MARK: Coding

    @Test func profileRoundTripsThroughJSON() throws {
        let profile = Self.makeProfile()
        let data = try ProfileStore.encode(profile)
        let decoded = try ProfileStore.decode(data)
        #expect(decoded == profile)
        // Encoding is deterministic (sorted keys), so two encodes give the same bytes.
        #expect(try ProfileStore.encode(decoded) == data)
    }

    @Test func titleMatchCasesRoundTrip() throws {
        let cases: [TitleMatch] = [.any, .exact("Inbox"), .contains("Docu"), .regex("^~/Works/.+"), .exact("")]
        for match in cases {
            let data = try JSONEncoder().encode(match)
            #expect(try JSONDecoder().decode(TitleMatch.self, from: data) == match)
        }
        // The cases in the fixture survive a full profile round trip too.
        let decoded = try ProfileStore.decode(try ProfileStore.encode(Self.makeProfile()))
        let matches = decoded.windows.map(\.titleMatch)
        #expect(matches.contains(.any))
        #expect(matches.contains(.exact("Downloads")))
        #expect(matches.contains(.contains("Docu")))
        #expect(matches.contains(.regex("^~/Works/.+")))
    }

    @Test func titleMatchJSONIsReadable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(TitleMatch.any), as: UTF8.self) == #"{"kind":"any"}"#)
        #expect(String(decoding: try encoder.encode(TitleMatch.contains("x")), as: UTF8.self)
                == #"{"kind":"contains","value":"x"}"#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TitleMatch.self, from: Data(#"{"kind":"fuzzy","value":"x"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TitleMatch.self, from: Data(#"{"kind":"exact"}"#.utf8))
        }
    }

    @Test func fileFormatIsPrettySortedAndISO8601() throws {
        let text = String(decoding: try ProfileStore.encode(Self.makeProfile()), as: UTF8.self)
        #expect(text.contains("\n"))
        #expect(text.contains("\"createdAt\" : \"2025-10-25T"))
        #expect(text.contains("Z\""))
        // Keys come out in alphabetical order.
        let order = ["\"createdAt\"", "\"displays\"", "\"icon\"", "\"id\"", "\"monitorSetKey\"", "\"name\"",
                     "\"notes\"", "\"options\"", "\"schemaVersion\"", "\"spaces\"", "\"updatedAt\"", "\"windows\""]
        var last = text.startIndex
        for key in order {
            let range = try #require(text.range(of: key, range: last..<text.endIndex), "missing or out of order: \(key)")
            last = range.upperBound
        }
    }

    @Test func missingOptionalFieldsFallBackToDefaults() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "00000000-0000-4000-8000-0000000000FF",
          "name": "Minimal",
          "createdAt": "2026-10-25T10:00:00Z",
          "updatedAt": "2026-10-25T10:00:30Z",
          "monitorSetKey": "k",
          "displays": [],
          "spaces": [],
          "windows": [{
            "id": "00000000-0000-4000-8000-000000000001",
            "app": {"name": "Notes"},
            "indexInApp": 0,
            "displayUUID": "d",
            "frame": [[0, 0], [100, 100]],
            "relativeFrame": [[0, 0], [1, 1]],
            "placement": {"unknown": {}},
            "isFullScreen": false,
            "isMinimized": false,
            "zIndex": 0
          }]
        }
        """
        let profile = try ProfileStore.decode(Data(json.utf8))
        #expect(profile.icon == "rectangle.3.group")
        #expect(profile.options == ProfileOptions())
        #expect(profile.notes == nil)
        #expect(profile.windows[0].restore)
        #expect(profile.windows[0].titleMatch == .any)
        #expect(profile.windows[0].title == nil)
        #expect(profile.updatedAt.timeIntervalSince(profile.createdAt) == 30)
    }

    // MARK: Store CRUD

    @Test func missingFolderListsNothingAndSaveCreatesIt() throws {
        try Self.withStore { store, folder in
            let listing = store.scan()
            #expect(listing.summaries.isEmpty && listing.problems.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            try store.save(Self.makeProfile())
            #expect(FileManager.default.fileExists(atPath: folder.path))
        }
    }

    @Test func saveListLoadRoundTrip() throws {
        try Self.withStore { store, folder in
            let work = Self.makeProfile(name: "Work")
            let home = Self.makeProfile(name: "Home")
            let savedWork = try store.save(work)
            try store.save(home)

            #expect(Self.fileNames(in: folder).contains("\(work.id.uuidString).json"))

            let list = store.list()
            #expect(list.map(\.name) == ["Home", "Work"])
            let summary = try #require(list.first { $0.id == work.id })
            #expect(summary.icon == "briefcase")
            #expect(summary.windowCount == 14)
            #expect(summary.updatedAt == savedWork.updatedAt)

            #expect(try store.load(work.id) == savedWork)
            #expect(try store.load(home.id).name == "Home")
        }
    }

    @Test func saveSetsUpdatedAtAndKeepsCreatedAt() throws {
        try Self.withStore { store, _ in
            let profile = Self.makeProfile()
            let before = Date()
            let saved = try store.save(profile)
            #expect(saved.updatedAt >= before.addingTimeInterval(-0.01))
            #expect(saved.updatedAt > profile.updatedAt)
            #expect(saved.createdAt == profile.createdAt)
            #expect(try store.load(profile.id).updatedAt == saved.updatedAt)

            // Saving again overwrites the same file and moves updatedAt forward.
            var edited = saved
            edited.name = "Work 2"
            let second = try store.save(edited)
            #expect(second.updatedAt >= saved.updatedAt)
            #expect(store.list().count == 1)
            #expect(try store.load(profile.id).name == "Work 2")
        }
    }

    @Test func datesDoNotDriftAcrossLoadAndSave() throws {
        try Self.withStore { store, _ in
            // Dates with milliseconds must come back unchanged, however often the profile is re-saved.
            var profile = Self.makeProfile()
            profile.createdAt = Date(timeIntervalSince1970: 1_761_400_000.002)
            let first = try store.save(profile)
            var current = first
            for _ in 0..<5 {
                current = try store.save(try store.load(first.id))
            }
            #expect(current.createdAt == first.createdAt)
            #expect(abs(first.createdAt.timeIntervalSince(profile.createdAt)) < 0.0005)
            #expect(try store.load(first.id).createdAt == first.createdAt)
        }
    }

    @Test func saveStampsTheCurrentSchemaVersion() throws {
        try Self.withStore { store, _ in
            var profile = Self.makeProfile()
            profile.schemaVersion = 0
            let saved = try store.save(profile)
            #expect(saved.schemaVersion == Profile.currentSchemaVersion)
            #expect(try store.load(profile.id).schemaVersion == Profile.currentSchemaVersion)
        }
    }

    @Test func loadUnknownIdThrowsNotFound() throws {
        try Self.withStore { store, _ in
            let id = UUID()
            #expect(throws: ProfileStoreError.notFound(id)) { try store.load(id) }
            #expect(throws: ProfileStoreError.notFound(id)) { try store.delete(id) }
            #expect(throws: ProfileStoreError.notFound(id)) { try store.rename(id, to: "x") }
            #expect(throws: ProfileStoreError.notFound(id)) { try store.duplicate(id) }
            #expect(throws: ProfileStoreError.notFound(id)) { try store.export(id, to: store.folder.appendingPathComponent("x.json")) }
        }
    }

    @Test func renameChangesNameOnly() throws {
        try Self.withStore { store, _ in
            let saved = try store.save(Self.makeProfile(name: "Work"))
            let renamed = try store.rename(saved.id, to: "  Office  ")
            #expect(renamed.name == "Office")
            let loaded = try store.load(saved.id)
            #expect(loaded.name == "Office")
            #expect(loaded.windows == saved.windows)
            #expect(loaded.spaces == saved.spaces)
            #expect(throws: ProfileStoreError.invalidName) { try store.rename(saved.id, to: "   ") }
            #expect(try store.load(saved.id).name == "Office")
        }
    }

    @Test func duplicateMakesAnIndependentCopy() throws {
        try Self.withStore { store, _ in
            let saved = try store.save(Self.makeProfile(name: "Work"))
            let copy = try store.duplicate(saved.id)
            #expect(copy.id != saved.id)
            #expect(copy.name == "Work copy")
            #expect(copy.options.hotkey == nil)
            #expect(copy.windows == saved.windows)
            #expect(copy.spaces == saved.spaces)
            #expect(copy.validate().isEmpty)
            #expect(store.list().count == 2)
            // The original keeps its hotkey.
            #expect(try store.load(saved.id).options.hotkey == "ctrl+opt+1")

            let named = try store.duplicate(saved.id, name: "Weekend")
            #expect(named.name == "Weekend")
            #expect(try store.duplicate(saved.id, name: "  ").name == "Work copy")
        }
    }

    @Test func deleteMovesTheFileToTrash() throws {
        try Self.withStore { store, folder in
            let saved = try store.save(Self.makeProfile())
            let trashed = try store.delete(saved.id)

            #expect(trashed.deletingLastPathComponent().lastPathComponent == "Trash")
            #expect(FileManager.default.fileExists(atPath: trashed.path))
            #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: saved.id).path))
            #expect(store.list().isEmpty)
            #expect(store.lastProblems.isEmpty)   // the Trash folder is not a problem
            #expect(Self.fileNames(in: folder) == ["Trash"])
            #expect(throws: ProfileStoreError.notFound(saved.id)) { try store.load(saved.id) }

            // The trashed file is still a valid profile.
            let rescued = try ProfileStore.decode(try Data(contentsOf: trashed))
            #expect(rescued.id == saved.id)

            // Saving and deleting the same profile again keeps both trashed copies.
            try store.save(saved)
            let second = try store.delete(saved.id)
            #expect(second != trashed)
            #expect(Self.fileNames(in: store.trashFolder).count == 2)
        }
    }

    // MARK: Atomic writes

    @Test func saveLeavesNoTempFiles() throws {
        try Self.withStore { store, folder in
            let profile = Self.makeProfile()
            for i in 0..<5 {
                var edited = profile
                edited.name = "Run \(i)"
                try store.save(edited)
            }
            #expect(Self.fileNames(in: folder) == ["\(profile.id.uuidString).json"])
        }
    }

    @Test func failedSaveKeepsTheOldFileAndCleansUp() throws {
        guard geteuid() != 0 else { return }   // root ignores directory permissions
        try Self.withStore { store, folder in
            let profile = Self.makeProfile(name: "Before")
            try store.save(profile)
            let before = try Data(contentsOf: store.fileURL(for: profile.id))

            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

            var edited = profile
            edited.name = "After"
            #expect(throws: (any Error).self) { try store.save(edited) }

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            #expect(try Data(contentsOf: store.fileURL(for: profile.id)) == before)
            #expect(try store.load(profile.id).name == "Before")
            #expect(Self.fileNames(in: folder) == ["\(profile.id.uuidString).json"])
        }
    }

    @Test func listIgnoresTempFilesAndForeignFiles() throws {
        try Self.withStore { store, folder in
            let profile = Self.makeProfile()
            try store.save(profile)
            try Self.write("half a file {", to: folder.appendingPathComponent(".\(profile.id.uuidString).json.ABC.tmp"))
            try Self.write("notes", to: folder.appendingPathComponent("readme.txt"))
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Old.json", isDirectory: true),
                                                    withIntermediateDirectories: true)
            let listing = store.scan()
            #expect(listing.summaries.map(\.id) == [profile.id])
            #expect(listing.problems.isEmpty)
        }
    }

    // MARK: Export and import

    @Test func exportThenImportIntoAnotherStore() throws {
        try Self.withStore { store, folder in
            let saved = try store.save(Self.makeProfile(name: "Travel"))
            let exportURL = folder.deletingLastPathComponent().appendingPathComponent("Travel.json")
            try store.export(saved.id, to: exportURL)
            #expect(try ProfileStore.decode(Data(contentsOf: exportURL)) == saved)

            // Exporting over an existing file replaces it.
            try store.export(saved.id, to: exportURL)

            let other = ProfileStore(folder: folder.deletingLastPathComponent().appendingPathComponent("Other", isDirectory: true))
            let imported = try other.importProfile(from: exportURL)
            #expect(imported == saved)             // no clash: same id, same dates, same hotkey
            #expect(try other.load(saved.id) == saved)
        }
    }

    @Test func importWithIdClashGetsANewId() throws {
        try Self.withStore { store, folder in
            let saved = try store.save(Self.makeProfile(name: "Work"))
            let exportURL = folder.deletingLastPathComponent().appendingPathComponent("Work.json")
            try store.export(saved.id, to: exportURL)

            let imported = try store.importProfile(from: exportURL)
            #expect(imported.id != saved.id)
            #expect(imported.options.hotkey == nil)
            #expect(imported.windows == saved.windows)
            #expect(imported.validate().isEmpty)

            // Both exist and the original is untouched.
            #expect(Set(store.list().map(\.id)) == [saved.id, imported.id])
            #expect(try store.load(saved.id) == saved)
            #expect(try store.load(imported.id) == imported)
        }
    }

    @Test func importRejectsBadFiles() throws {
        try Self.withStore { store, folder in
            let dir = folder.deletingLastPathComponent()

            let garbage = dir.appendingPathComponent("garbage.json")
            try Self.write("not json at all", to: garbage)
            #expect(throws: ProfileStoreError.self) { try store.importProfile(from: garbage) }

            var broken = Self.makeProfile()
            broken.name = ""
            let invalid = dir.appendingPathComponent("invalid.json")
            try ProfileStore.encode(broken).write(to: invalid)
            #expect(throws: ProfileStoreError.self) { try store.importProfile(from: invalid) }

            let missing = dir.appendingPathComponent("missing.json")
            #expect(throws: (any Error).self) { try store.importProfile(from: missing) }

            #expect(store.list().isEmpty)
        }
    }

    // MARK: Corrupt files

    @Test func corruptFilesAreSkippedAndReported() throws {
        try Self.withStore { store, folder in
            let good = try store.save(Self.makeProfile(name: "Good"))

            let truncated = folder.appendingPathComponent("\(UUID().uuidString).json")
            let validText = String(decoding: try ProfileStore.encode(Self.makeProfile()), as: UTF8.self)
            try Self.write(String(validText.prefix(200)), to: truncated)

            let notJSON = folder.appendingPathComponent("\(UUID().uuidString).json")
            try Self.write("\u{0}\u{1}garbage", to: notJSON)

            let wrongShape = folder.appendingPathComponent("\(UUID().uuidString).json")
            try Self.write("[1, 2, 3]", to: wrongShape)

            let noVersion = folder.appendingPathComponent("\(UUID().uuidString).json")
            try Self.write(#"{"name": "x"}"#, to: noVersion)

            let wrongType = folder.appendingPathComponent("\(UUID().uuidString).json")
            try Self.write(#"{"schemaVersion": 1, "id": "oops", "name": 5}"#, to: wrongType)

            let empty = folder.appendingPathComponent("\(UUID().uuidString).json")
            try Self.write("", to: empty)

            // A valid profile under the wrong file name is reported too.
            let misnamed = folder.appendingPathComponent("\(UUID().uuidString).json")
            try ProfileStore.encode(Self.makeProfile(name: "Misnamed")).write(to: misnamed)

            let listing = store.scan()
            #expect(listing.summaries.map(\.id) == [good.id])
            let skipped = Set(listing.problems.map(\.file.lastPathComponent))
            #expect(skipped == Set([truncated, notJSON, wrongShape, noVersion, wrongType, empty, misnamed].map(\.lastPathComponent)))
            #expect(listing.problems.allSatisfy { !$0.reason.isEmpty })
            #expect(store.lastProblems.count == 7)
            #expect(store.list().map(\.id) == [good.id])

            let misnamedProblem = try #require(listing.problems.first { $0.file.lastPathComponent == misnamed.lastPathComponent })
            #expect(misnamedProblem.reason.contains("file name"))
        }
    }

    @Test func loadingACorruptFileThrowsACorruptError() throws {
        try Self.withStore { store, _ in
            let id = UUID()
            try Self.write("{ nope", to: store.fileURL(for: id))
            do {
                _ = try store.load(id)
                Issue.record("load should have thrown")
            } catch let error as ProfileStoreError {
                guard case .corrupt(let source, _) = error else {
                    Issue.record("expected .corrupt, got \(error)")
                    return
                }
                #expect(source == "\(id.uuidString).json")
            }
        }
    }

    @Test func decodeErrorsNameTheBrokenField() throws {
        var object = try #require(JSONSerialization.jsonObject(with: try ProfileStore.encode(Self.makeProfile())) as? [String: Any])
        var windows = try #require(object["windows"] as? [[String: Any]])
        windows[3].removeValue(forKey: "displayUUID")
        object["windows"] = windows
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try ProfileStore.decode(data, source: "test.json")
            Issue.record("decode should have thrown")
        } catch let error as ProfileStoreError {
            let text = error.errorDescription ?? ""
            #expect(text.contains("test.json"))
            #expect(text.contains("windows"))
            #expect(text.contains("displayUUID"))
        }
    }

    // MARK: Schema migration

    @Test func migrateVersionOneIsIdentity() throws {
        let json: [String: Any] = ["schemaVersion": 1, "name": "x"]
        let migrated = try ProfileStore.migrate(json: json, from: 1)
        #expect(migrated["schemaVersion"] as? Int == 1)
        #expect(migrated["name"] as? String == "x")
    }

    @Test func migrateRejectsFutureAndInvalidVersions() {
        #expect(throws: ProfileStoreError.unsupportedSchema(found: 2, supported: 1)) {
            try ProfileStore.migrate(json: [:], from: 2)
        }
        #expect(throws: ProfileStoreError.unsupportedSchema(found: 99, supported: 1)) {
            try ProfileStore.migrate(json: [:], from: 99)
        }
        #expect(throws: ProfileStoreError.unsupportedSchema(found: 0, supported: 1)) {
            try ProfileStore.migrate(json: [:], from: 0)
        }
        let message = ProfileStoreError.unsupportedSchema(found: 2, supported: 1).errorDescription ?? ""
        #expect(message.contains("newer version"))
        #expect(message.contains("schema 2"))
    }

    @Test func aFutureSchemaFileIsRefusedWithAClearError() throws {
        try Self.withStore { store, folder in
            var object = try #require(JSONSerialization.jsonObject(with: try ProfileStore.encode(Self.makeProfile())) as? [String: Any])
            object["schemaVersion"] = 7
            let future = Self.makeProfile()
            object["id"] = future.id.uuidString
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL(for: future.id))

            #expect(throws: ProfileStoreError.unsupportedSchema(found: 7, supported: 1)) { try store.load(future.id) }

            let listing = store.scan()
            #expect(listing.summaries.isEmpty)
            let problem = try #require(listing.problems.first)
            #expect(problem.reason.contains("newer version"))
        }
    }

    // MARK: validate()

    @Test func validateFlagsAnEmptyName() {
        var profile = Self.makeProfile()
        profile.name = "  \n"
        #expect(profile.validate().contains { $0.contains("name is empty") })
    }

    @Test func validateFlagsDanglingFullScreenWindowIDs() {
        var profile = Self.makeProfile()
        let ghost = Self.wid(99)
        profile.spaces[0].fullScreenWindowIDs = [ghost]
        let problems = profile.validate()
        #expect(problems.count == 1)
        #expect(problems[0].contains(ghost.uuidString))
        #expect(problems[0].contains("not in the profile"))
    }

    @Test func validateFlagsDuplicateWindowIds() {
        var profile = Self.makeProfile()
        profile.windows[1].id = profile.windows[0].id
        let problems = profile.validate()
        #expect(problems.contains { $0.contains(Self.wid(1).uuidString) && $0.contains("more than one window") })
        // The Split View check still resolves ids that exist; window 2 is now dangling for its Space.
        #expect(problems.contains { $0.contains(Self.wid(2).uuidString) && $0.contains("not in the profile") })
    }

    @Test func validateFlagsStructuralProblems() {
        var profile = Self.makeProfile()
        profile.spaces.append(SpaceSnapshot(displayUUID: Self.samsungUUID, position: 2, kind: .desktop, desktopNumber: 2))
        profile.spaces.append(SpaceSnapshot(displayUUID: "UNKNOWN", position: 0, kind: .desktop, desktopNumber: 1))
        profile.windows[2].displayUUID = "UNKNOWN"
        profile.displays.append(Self.samsung)
        profile.spaces[7].fullScreenWindowIDs = [Self.wid(1)]
        let problems = profile.validate()
        #expect(problems.contains { $0.contains("more than one Space at position 2") })
        #expect(problems.contains { $0.contains("Space 0 is on display UNKNOWN") })
        #expect(problems.contains { $0.contains("is on display UNKNOWN") && $0.contains("Finder") })
        #expect(problems.contains { $0.contains("Display \(Self.samsungUUID) is listed more than once") })
        #expect(problems.contains { $0.contains(Self.wid(1).uuidString) && $0.contains("more than one full-screen Space") })
    }

    @Test func validateFlagsANewerSchemaVersion() {
        var profile = Self.makeProfile()
        profile.schemaVersion = 5
        #expect(profile.validate().contains { $0.contains("schema version 5") })
    }
}
