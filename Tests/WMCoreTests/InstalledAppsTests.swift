import Foundation
import Testing
@testable import WMCore

/// A scratch folder under the temp directory, removed when the test ends.
private final class ScratchFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstalledAppsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes `<name>.app/Contents/Info.plist` with the given keys (no plist when `info` is nil).
    @discardableResult
    func app(_ name: String, info: [String: Any]?, in folder: URL? = nil) -> URL {
        let base = folder ?? url
        let bundle = base.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if let info {
            let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try! data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        return bundle
    }
}

@Test func scanListsNameAndBundleIdentifier() {
    let folder = ScratchFolder()
    let bundle = folder.app("Notes", info: ["CFBundleName": "Notes", "CFBundleIdentifier": "com.apple.Notes"])
    let apps = InstalledApps.scan(folders: [folder.url])
    #expect(apps.count == 1)
    #expect(apps.first?.name == "Notes")
    #expect(apps.first?.bundleID == "com.apple.Notes")
    #expect(apps.first?.url.standardizedFileURL == bundle.standardizedFileURL)
    #expect(apps.first?.isBackgroundOnly == false)
}

@Test func scanPrefersDisplayNameThenBundleNameThenFileName() {
    let folder = ScratchFolder()
    folder.app("Alpha", info: ["CFBundleDisplayName": "Display Alpha", "CFBundleName": "Alpha", "CFBundleIdentifier": "t.alpha"])
    folder.app("Beta", info: ["CFBundleName": "Bee", "CFBundleIdentifier": "t.beta"])
    folder.app("Gamma", info: ["CFBundleIdentifier": "t.gamma"])
    let names = Dictionary(uniqueKeysWithValues: InstalledApps.scan(folders: [folder.url]).map { ($0.bundleID, $0.name) })
    #expect(names["t.alpha"] == "Display Alpha")
    #expect(names["t.beta"] == "Bee")
    #expect(names["t.gamma"] == "Gamma")
}

@Test func scanIgnoresNonAppsAndBundlesWithoutBundleIdentifier() {
    let folder = ScratchFolder()
    folder.app("Good", info: ["CFBundleIdentifier": "t.good"])
    folder.app("NoID", info: ["CFBundleName": "NoID"])
    folder.app("EmptyID", info: ["CFBundleIdentifier": "   "])
    folder.app("NoPlist", info: nil)
    try! Data("x".utf8).write(to: folder.url.appendingPathComponent("readme.txt"))
    try! FileManager.default.createDirectory(
        at: folder.url.appendingPathComponent("Folder.folder/Contents", isDirectory: true),
        withIntermediateDirectories: true)
    let apps = InstalledApps.scan(folders: [folder.url])
    #expect(apps.map(\.bundleID) == ["t.good"])
}

@Test func scanSkipsMissingFolders() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
    let folder = ScratchFolder()
    folder.app("Only", info: ["CFBundleIdentifier": "t.only"])
    #expect(InstalledApps.scan(folders: [missing, folder.url]).map(\.bundleID) == ["t.only"])
}

@Test func scanMarksBackgroundOnlyHelpers() {
    let folder = ScratchFolder()
    folder.app("Menu", info: ["CFBundleIdentifier": "t.menu", "LSUIElement": true])
    folder.app("Agent", info: ["CFBundleIdentifier": "t.agent", "LSBackgroundOnly": "1"])
    folder.app("Normal", info: ["CFBundleIdentifier": "t.normal"])
    let flags = Dictionary(uniqueKeysWithValues: InstalledApps.scan(folders: [folder.url]).map { ($0.bundleID, $0.isBackgroundOnly) })
    #expect(flags["t.menu"] == true)
    #expect(flags["t.agent"] == true)
    #expect(flags["t.normal"] == false)
}

@Test func scanDedupesByBundleIdentifierKeepingFirstFolder() {
    let first = ScratchFolder()
    let second = ScratchFolder()
    first.app("Safari Copy", info: ["CFBundleName": "Safari", "CFBundleIdentifier": "com.apple.Safari"])
    second.app("Safari", info: ["CFBundleName": "Safari Old", "CFBundleIdentifier": "com.apple.Safari"])
    second.app("Unique", info: ["CFBundleIdentifier": "t.unique"])
    let apps = InstalledApps.scan(folders: [first.url, second.url])
    #expect(apps.count == 2)
    let safari = apps.first { $0.bundleID == "com.apple.Safari" }
    #expect(safari?.name == "Safari")
    #expect(safari?.url.deletingLastPathComponent().standardizedFileURL == first.url.standardizedFileURL)
}

@Test func scanSortsByNameCaseInsensitively() {
    let folder = ScratchFolder()
    folder.app("zeta", info: ["CFBundleName": "zeta", "CFBundleIdentifier": "t.z"])
    folder.app("Alpha", info: ["CFBundleName": "Alpha", "CFBundleIdentifier": "t.a"])
    folder.app("mango", info: ["CFBundleName": "mango", "CFBundleIdentifier": "t.m"])
    #expect(InstalledApps.scan(folders: [folder.url]).map(\.name) == ["Alpha", "mango", "zeta"])
}

@Test func defaultFoldersCoverSystemAndUserApplications() {
    let paths = InstalledApps.defaultFolders.map(\.path)
    #expect(paths.contains("/Applications"))
    #expect(paths.contains("/System/Applications"))
    #expect(paths.contains("/Applications/Utilities"))
    let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
    #expect(paths.contains(home))
}

@Test func mergeFlagsRunningAppsAndKeepsRunningOnlyOnes() {
    let folder = ScratchFolder()
    let safariURL = folder.app("Safari", info: ["CFBundleName": "Safari", "CFBundleIdentifier": "com.apple.Safari"])
    let notesURL = folder.app("Notes", info: ["CFBundleName": "Notes", "CFBundleIdentifier": "com.apple.Notes"])
    let installed = InstalledApps.scan(folders: [folder.url])

    let running: [(name: String, bundleID: String, url: URL?)] = [
        (name: "Safari", bundleID: "com.apple.Safari", url: nil),
        (name: "Helper", bundleID: "t.helper", url: nil),
    ]
    let entries = InstalledApps.merge(running: running, installed: installed)

    #expect(entries.map(\.bundleID) == ["t.helper", "com.apple.Notes", "com.apple.Safari"])

    let safari = entries.first { $0.bundleID == "com.apple.Safari" }
    #expect(safari?.isRunning == true)
    #expect(safari?.isInstalled == true)
    #expect(safari?.url?.standardizedFileURL == safariURL.standardizedFileURL)

    let notes = entries.first { $0.bundleID == "com.apple.Notes" }
    #expect(notes?.isRunning == false)
    #expect(notes?.isInstalled == true)
    #expect(notes?.url?.standardizedFileURL == notesURL.standardizedFileURL)

    let helper = entries.first { $0.bundleID == "t.helper" }
    #expect(helper?.isRunning == true)
    #expect(helper?.isInstalled == false)
    #expect(helper?.url == nil)
}

@Test func mergeWithNothingRunningListsInstalledApps() {
    let installed = [
        InstalledApp(name: "b", bundleID: "t.b", url: URL(fileURLWithPath: "/Applications/b.app")),
        InstalledApp(name: "A", bundleID: "t.a", url: URL(fileURLWithPath: "/Applications/A.app")),
    ]
    let entries = InstalledApps.merge(running: [], installed: installed)
    #expect(entries.map(\.name) == ["A", "b"])
    #expect(entries.allSatisfy { !$0.isRunning && $0.isInstalled })
}

@Test func isInstalledChecksScanResultByBundleIdentifier() {
    let installed = [InstalledApp(name: "Notes", bundleID: "com.apple.Notes", url: URL(fileURLWithPath: "/Applications/Notes.app"))]
    #expect(InstalledApps.isInstalled(bundleID: "com.apple.Notes", in: installed))
    #expect(InstalledApps.isInstalled(bundleID: "COM.APPLE.NOTES", in: installed))
    #expect(!InstalledApps.isInstalled(bundleID: "com.apple.Safari", in: installed))
}
