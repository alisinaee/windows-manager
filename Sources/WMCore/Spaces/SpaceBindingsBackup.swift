import Foundation

// P3.6 Space preferences backup, restore with confirmation, and login repair advice.
//
// A backup is one XML property list with the whole com.apple.spaces domain and the Mission Control keyboard
// bindings from com.apple.symbolichotkeys (ids 79-82 and 118-129). Reading uses CFPreferences. Writing goes
// through `defaults import` and `killall Dock`, both run through `CommandRunning`, so tests never run them.
// Nothing here runs by itself: `restore` refuses unless the caller confirms.

/// Reads every key of one preference domain. The live version is `SpaceBindingsBackup.livePreferences`.
public typealias PreferenceReading = (_ domain: String) -> [String: Any]

/// Runs a command-line tool. The live version is `ProcessCommandRunner`.
public protocol CommandRunning {
    func run(_ path: String, arguments: [String]) throws -> CommandResult
}

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stderr: String

    public init(status: Int32, stderr: String = "") {
        self.status = status
        self.stderr = stderr
    }
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ path: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw SpaceBindingsBackupError.commandFailed("cannot run \(path): \(error.localizedDescription)")
        }
        // Output is tiny, so reading one pipe after the other cannot block the child.
        _ = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus,
                             stderr: String(decoding: stderr, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum SpaceBindingsBackupError: Error, Equatable, LocalizedError {
    /// `restore` was called without `confirmed: true`. Nothing was changed.
    case notConfirmed
    case backupFailed(String)
    case invalidBackup(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfirmed:
            return "Restore needs confirmation. Nothing was changed."
        case .backupFailed(let text):
            return "The Space backup failed: \(text)"
        case .invalidBackup(let text):
            return "The backup file cannot be restored: \(text)"
        case .commandFailed(let text):
            return "A system command failed: \(text)"
        }
    }
}

/// One backup file on disk. `reason` is the sanitized reason from the file name.
public struct BackupInfo: Equatable, Hashable, Codable, Identifiable, Sendable {
    public var url: URL
    public var date: Date
    public var reason: String

    public init(url: URL, date: Date, reason: String) {
        self.url = url
        self.date = date
        self.reason = reason
    }

    public var id: String { url.lastPathComponent }
}

public struct SpaceBindingsBackup {
    public static let spacesDomain = "com.apple.spaces"
    public static let spacesRootKey = "SpacesDisplayConfiguration"
    public static let hotkeysDomain = "com.apple.symbolichotkeys"
    public static let hotkeysRootKey = "AppleSymbolicHotKeys"
    /// Mission Control keys: 79-82 move left/right a space; 118-129 switch to Desktop 1...12.
    public static let hotkeyIDs: [String] = ["79", "80", "81", "82"] + (118...129).map { String($0) }
    public static let retainedCount = 20
    public static let formatVersion = 1

    /// ~/Library/Application Support/WindowsManager/Backups
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WindowsManager/Backups", isDirectory: true)
    }

    /// Whole domain through CFPreferences (key list, then each value). Read only.
    public static func livePreferences(_ domain: String) -> [String: Any] {
        let keys = (CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesCurrentUser,
                                             kCFPreferencesAnyHost) as? [String]) ?? []
        var values: [String: Any] = [:]
        for key in keys {
            if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) {
                values[key] = value
            }
        }
        return values
    }

    public let folder: URL
    private let reader: PreferenceReading
    private let runner: CommandRunning
    private let clock: () -> Date

    public init(folder: URL = SpaceBindingsBackup.defaultFolder,
                reader: @escaping PreferenceReading = SpaceBindingsBackup.livePreferences,
                runner: CommandRunning = ProcessCommandRunner(),
                clock: @escaping () -> Date = { Date() }) {
        self.folder = folder
        self.reader = reader
        self.runner = runner
        self.clock = clock
    }

    // MARK: Backup

    /// Writes one backup file and prunes the folder to the newest `retainedCount` backups. Only files with the
    /// backup name pattern are ever removed.
    @discardableResult
    public func backupNow(reason: String) throws -> BackupInfo {
        let spaces = reader(Self.spacesDomain)
        guard spaces[Self.spacesRootKey] != nil else {
            throw SpaceBindingsBackupError.backupFailed("\(Self.spacesDomain) has no \(Self.spacesRootKey) key")
        }
        guard let allBindings = reader(Self.hotkeysDomain)[Self.hotkeysRootKey] as? [String: Any] else {
            throw SpaceBindingsBackupError.backupFailed("\(Self.hotkeysDomain) has no \(Self.hotkeysRootKey) key")
        }
        var bindings: [String: Any] = [:]
        for id in Self.hotkeyIDs {
            if let value = allBindings[id] { bindings[id] = value }
        }

        let cleanReason = Self.sanitize(reason)
        let (url, stamped) = try uniqueURL(date: clock(), reason: cleanReason)
        let root: [String: Any] = [
            "format": Self.formatVersion,
            "reason": reason,
            "createdAt": stamped,
            "domains": [
                Self.spacesDomain: spaces,
                Self.hotkeysDomain: [Self.hotkeysRootKey: bindings],
            ],
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw SpaceBindingsBackupError.backupFailed(error.localizedDescription)
        }

        let info = BackupInfo(url: url, date: stamped, reason: cleanReason)
        for old in list().dropFirst(Self.retainedCount) {
            try? FileManager.default.removeItem(at: old.url)
        }
        return info
    }

    /// Backups in this folder, newest first. Files that do not match the backup name pattern are ignored.
    public func list() -> [BackupInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return names.compactMap(Self.parse).sorted { $0.date > $1.date }
    }

    // MARK: Restore

    /// Puts a backup back: `defaults import` for both domains, then one `killall Dock` when `killDock` is true.
    /// The hotkey subset is merged into the current bindings first, so other shortcuts stay as they are.
    /// Throws `.notConfirmed` unless `confirmed` is true, and changes nothing when the file is not a valid backup.
    public func restore(_ info: BackupInfo, confirmed: Bool, killDock: Bool = true) throws {
        guard confirmed else { throw SpaceBindingsBackupError.notConfirmed }
        let domains = try Self.readDomains(info.url)
        guard let spaces = domains[Self.spacesDomain] as? [String: Any], spaces[Self.spacesRootKey] != nil else {
            throw SpaceBindingsBackupError.invalidBackup("\(Self.spacesDomain) is missing \(Self.spacesRootKey)")
        }
        guard let savedHotkeys = domains[Self.hotkeysDomain] as? [String: Any],
              let savedBindings = savedHotkeys[Self.hotkeysRootKey] as? [String: Any] else {
            throw SpaceBindingsBackupError.invalidBackup("\(Self.hotkeysDomain) is missing \(Self.hotkeysRootKey)")
        }

        var hotkeys = reader(Self.hotkeysDomain)
        var bindings = (hotkeys[Self.hotkeysRootKey] as? [String: Any]) ?? [:]
        for id in Self.hotkeyIDs {
            bindings[id] = savedBindings[id]
        }
        hotkeys[Self.hotkeysRootKey] = bindings

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowsManagerRestore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let spacesFile = work.appendingPathComponent("\(Self.spacesDomain).plist")
        let hotkeysFile = work.appendingPathComponent("\(Self.hotkeysDomain).plist")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try Self.writePlist(spaces, to: spacesFile)
            try Self.writePlist(hotkeys, to: hotkeysFile)
        } catch let error as SpaceBindingsBackupError {
            throw error
        } catch {
            throw SpaceBindingsBackupError.commandFailed("cannot prepare the import: \(error.localizedDescription)")
        }

        try runChecked("/usr/bin/defaults", ["import", Self.spacesDomain, spacesFile.path])
        try runChecked("/usr/bin/defaults", ["import", Self.hotkeysDomain, hotkeysFile.path])
        if killDock {
            try runChecked("/usr/bin/killall", ["Dock"])
        }
    }

    // MARK: Helpers

    private func runChecked(_ path: String, _ arguments: [String]) throws {
        let result = try runner.run(path, arguments: arguments)
        guard result.status == 0 else {
            let detail = result.stderr.isEmpty ? "" : ": \(result.stderr)"
            throw SpaceBindingsBackupError.commandFailed("\(path) exited \(result.status)\(detail)")
        }
    }

    private func uniqueURL(date: Date, reason: String) throws -> (URL, Date) {
        var stamped = date
        for _ in 0..<10_000 {
            let url = folder.appendingPathComponent("\(Self.stamp(stamped))-\(reason).plist")
            if !FileManager.default.fileExists(atPath: url.path) { return (url, stamped) }
            stamped = stamped.addingTimeInterval(0.001)
        }
        throw SpaceBindingsBackupError.backupFailed("no free file name in \(folder.path)")
    }

    private static func writePlist(_ dictionary: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// The domains of a backup file, after checking that it is a version 1 backup.
    static func readDomains(_ url: URL) throws -> [String: Any] {
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SpaceBindingsBackupError.invalidBackup("cannot read \(name)")
        }
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw SpaceBindingsBackupError.invalidBackup("\(name) is not a property list")
        }
        guard let root = object as? [String: Any], let format = root["format"] as? Int, format == formatVersion,
              let domains = root["domains"] as? [String: Any] else {
            throw SpaceBindingsBackupError.invalidBackup("\(name) is not a version \(formatVersion) backup")
        }
        return domains
    }

    /// File name: "<yyyyMMdd-HHmmss-SSS>-<reason>.plist". Returns nil for any other file.
    static func parse(_ url: URL) -> BackupInfo? {
        let name = url.lastPathComponent
        guard name.hasSuffix(".plist") else { return nil }
        let body = String(name.dropLast(".plist".count))
        guard body.count >= stampLength + 2 else { return nil }
        let stampText = String(body.prefix(stampLength))
        let rest = body.dropFirst(stampLength)
        guard rest.hasPrefix("-") else { return nil }
        guard let date = stampFormatter.date(from: stampText), stamp(date) == stampText else { return nil }
        return BackupInfo(url: url, date: date, reason: String(rest.dropFirst()))
    }

    /// Lower-case letters and digits, other runs become "-". Empty becomes "manual". At most 40 characters.
    static func sanitize(_ reason: String) -> String {
        var out = ""
        for character in reason.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                out.append(character)
            } else if out.last != "-" {
                out.append("-")
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if out.count > 40 {
            out = String(out.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return out.isEmpty ? "manual" : out
    }

    static let stampLength = 19

    static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}

// MARK: - Login repair

/// The Space order of every display at one moment, as slot keys (the same keys `SpaceGuard` uses).
public struct SpaceOrderSnapshot: Codable, Equatable, Sendable {
    public var takenAt: Date
    /// Display identifier to its slot keys, left to right.
    public var orders: [String: [String]]
    /// The backup taken while this snapshot was good, when one was made.
    public var backup: BackupInfo?

    public init(displays: [DisplaySpaceOrder], takenAt: Date, backup: BackupInfo? = nil) {
        var orders: [String: [String]] = [:]
        for display in displays {
            orders[display.displayID] = display.slots.map(\.key)
        }
        self.takenAt = takenAt
        self.orders = orders
        self.backup = backup
    }
}

public struct LoginRepairAdvice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case fine
        /// Fewer Desktops than the last known good layout, typical after a bad login.
        case spacesLost(count: Int)
        /// Same Desktops, different order (or other Spaces added or removed).
        case reordered
        case noBaseline
    }

    public var kind: Kind
    public var sentence: String
    /// The newest backup taken while the last known good layout was in place.
    public var suggestedBackup: BackupInfo?

    public init(kind: Kind, sentence: String, suggestedBackup: BackupInfo?) {
        self.kind = kind
        self.sentence = sentence
        self.suggestedBackup = suggestedBackup
    }
}

public enum LoginRepair {
    /// Compares the current layout with the last known good one. Pure: displays that are not in both are skipped.
    public static func assess(lastKnownGood: SpaceOrderSnapshot?, current: SpaceOrderSnapshot) -> LoginRepairAdvice {
        guard let good = lastKnownGood else {
            return LoginRepairAdvice(
                kind: .noBaseline,
                sentence: "No known-good Space layout is saved yet. Back up while the Spaces look right, "
                    + "so a later login problem can be compared with them.",
                suggestedBackup: nil)
        }

        var lost = 0
        var reordered = false
        for (display, before) in good.orders {
            guard let now = current.orders[display] else { continue }
            let beforeDesktops = desktopCount(before)
            let nowDesktops = desktopCount(now)
            if nowDesktops < beforeDesktops { lost += beforeDesktops - nowDesktops }
            if now != before { reordered = true }
        }

        let when = good.takenAt.formatted(date: .abbreviated, time: .shortened)
        let backupText: String
        if let backup = good.backup {
            backupText = "The backup from \(backup.date.formatted(date: .abbreviated, time: .shortened)) "
                + "can bring them back: restore it from the list below."
        } else {
            backupText = "No backup from that time is recorded, so no restore is suggested."
        }

        if lost > 0 {
            return LoginRepairAdvice(
                kind: .spacesLost(count: lost),
                sentence: "Mission Control has \(lost) fewer Desktop\(lost == 1 ? "" : "s") than the known-good "
                    + "layout from \(when). This is typical after a bad login. \(backupText)",
                suggestedBackup: good.backup)
        }
        if reordered {
            return LoginRepairAdvice(
                kind: .reordered,
                sentence: "The Space order differs from the known-good layout from \(when). \(backupText)",
                suggestedBackup: good.backup)
        }
        return LoginRepairAdvice(
            kind: .fine,
            sentence: "The Spaces match the known-good layout from \(when).",
            suggestedBackup: good.backup)
    }

    private static func desktopCount(_ keys: [String]) -> Int {
        keys.filter { $0.hasPrefix("desktop:") }.count
    }
}

/// Keeps the last known good Space layout as JSON in the backup folder (`last-known-good.json`).
public struct SpaceSnapshotStore {
    public let url: URL

    public init(folder: URL = SpaceBindingsBackup.defaultFolder) {
        url = folder.appendingPathComponent("last-known-good.json")
    }

    public func load() -> SpaceOrderSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SpaceOrderSnapshot.self, from: data)
    }

    /// Saves `snapshot` as the new last known good layout only when `report` is clean. Returns true when saved.
    /// The caller compares against a non-empty expected order: an empty expected order is always clean.
    @discardableResult
    public func save(_ snapshot: SpaceOrderSnapshot, report: SpaceGuardReport) throws -> Bool {
        guard report.isClean, !snapshot.orders.isEmpty else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
    }
}
