import Foundation

// App library for the Profile Studio Builder (plan B2 "App library", PM4).
// `scan` reads Info.plist of the .app bundles directly inside each folder (no NSWorkspace). `merge` is pure:
// it combines a list of running apps with a scan result and flags what is running.

/// An app bundle found on disk.
public struct InstalledApp: Equatable, Sendable {
    public let name: String
    public let bundleID: String
    public let url: URL
    /// True when Info.plist sets `LSUIElement` or `LSBackgroundOnly` (menu bar helpers and agents).
    public let isBackgroundOnly: Bool

    public init(name: String, bundleID: String, url: URL, isBackgroundOnly: Bool = false) {
        self.name = name
        self.bundleID = bundleID
        self.url = url
        self.isBackgroundOnly = isBackgroundOnly
    }
}

/// One row of the builder's app library: a running app, an installed app, or both.
public struct LibraryEntry: Equatable, Sendable {
    public let name: String
    public let bundleID: String
    public let url: URL?
    public let isRunning: Bool
    public let isInstalled: Bool
    public let isBackgroundOnly: Bool

    public init(name: String, bundleID: String, url: URL?, isRunning: Bool, isInstalled: Bool, isBackgroundOnly: Bool) {
        self.name = name
        self.bundleID = bundleID
        self.url = url
        self.isRunning = isRunning
        self.isInstalled = isInstalled
        self.isBackgroundOnly = isBackgroundOnly
    }
}

public enum InstalledApps {
    /// The folders the library scans, in priority order (an app found in an earlier folder wins).
    public static var defaultFolders: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// Lists the `.app` bundles directly inside each folder. Folders that do not exist or cannot be read
    /// are skipped. Bundles without a bundle identifier or without a readable Info.plist are skipped.
    /// Dedupes by bundle identifier (case-insensitive; the first folder in `folders` wins) and sorts by
    /// name, case-insensitively.
    public static func scan(folders: [URL] = InstalledApps.defaultFolders) -> [InstalledApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [InstalledApp] = []
        for folder in folders {
            guard let children = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for bundleURL in children.sorted(by: { $0.path < $1.path }) where bundleURL.pathExtension.lowercased() == "app" {
                guard let app = readBundle(bundleURL) else { continue }
                let key = app.bundleID.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(app)
            }
        }
        return sortedByName(result)
    }

    /// Pure merge of running apps with a scan result. Running apps get `isRunning`; running apps that are not
    /// installed are included with `isInstalled == false`. Keyed by bundle identifier (case-insensitive); the
    /// running entry supplies the name, the installed entry fills in a missing URL. Sorted by name.
    public static func merge(
        running: [(name: String, bundleID: String, url: URL?)],
        installed: [InstalledApp]
    ) -> [LibraryEntry] {
        var installedByKey: [String: InstalledApp] = [:]
        for app in installed where installedByKey[app.bundleID.lowercased()] == nil {
            installedByKey[app.bundleID.lowercased()] = app
        }
        var entries: [LibraryEntry] = []
        var usedKeys = Set<String>()
        for run in running {
            let key = run.bundleID.lowercased()
            guard !usedKeys.contains(key) else { continue }
            usedKeys.insert(key)
            let match = installedByKey[key]
            entries.append(LibraryEntry(
                name: run.name,
                bundleID: run.bundleID,
                url: run.url ?? match?.url,
                isRunning: true,
                isInstalled: match != nil,
                isBackgroundOnly: match?.isBackgroundOnly ?? false
            ))
        }
        for app in installed where !usedKeys.contains(app.bundleID.lowercased()) {
            usedKeys.insert(app.bundleID.lowercased())
            entries.append(LibraryEntry(
                name: app.name,
                bundleID: app.bundleID,
                url: app.url,
                isRunning: false,
                isInstalled: true,
                isBackgroundOnly: app.isBackgroundOnly
            ))
        }
        return entries.sorted(by: entryOrder)
    }

    /// True when `bundleID` is one of the scanned apps (bundle identifiers compare case-insensitively).
    public static func isInstalled(bundleID: String, in installed: [InstalledApp]) -> Bool {
        let key = bundleID.lowercased()
        return installed.contains { $0.bundleID.lowercased() == key }
    }

    // MARK: - Private

    private static func readBundle(_ bundleURL: URL) -> InstalledApp? {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let bundleID = nonEmptyString(plist["CFBundleIdentifier"])
        else { return nil }
        let fileName = bundleURL.deletingPathExtension().lastPathComponent
        let name = nonEmptyString(plist["CFBundleDisplayName"])
            ?? nonEmptyString(plist["CFBundleName"])
            ?? fileName
        let background = isTrue(plist["LSUIElement"]) || isTrue(plist["LSBackgroundOnly"])
        return InstalledApp(name: name, bundleID: bundleID, url: bundleURL.standardizedFileURL, isBackgroundOnly: background)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isTrue(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["1", "true", "yes"].contains(string.lowercased()) }
        return false
    }

    private static func sortedByName(_ apps: [InstalledApp]) -> [InstalledApp] {
        apps.sorted { lhs, rhs in
            let order = lhs.name.compare(rhs.name, options: [.caseInsensitive])
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.bundleID < rhs.bundleID
        }
    }

    private static func entryOrder(_ lhs: LibraryEntry, _ rhs: LibraryEntry) -> Bool {
        let order = lhs.name.compare(rhs.name, options: [.caseInsensitive])
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.bundleID < rhs.bundleID
    }
}
