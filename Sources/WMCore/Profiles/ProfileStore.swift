import Foundation

// The versioned JSON store for profiles (phase P2.4).
// One file per profile: <folder>/<id>.json, pretty printed with sorted keys and ISO-8601 dates.
// Writes go to a temp file first and are then swapped in, so a crash never leaves a half-written profile.
// Deleted profiles move to <folder>/Trash/ and can be recovered by hand.

/// A short description of a stored profile, cheap enough to show in a menu.
public struct ProfileSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var icon: String
    public var updatedAt: Date
    public var windowCount: Int

    public init(id: UUID, name: String, icon: String, updatedAt: Date, windowCount: Int) {
        self.id = id
        self.name = name
        self.icon = icon
        self.updatedAt = updatedAt
        self.windowCount = windowCount
    }

    init(_ profile: Profile) {
        self.init(id: profile.id, name: profile.name, icon: profile.icon, updatedAt: profile.updatedAt,
                  windowCount: profile.windows.count)
    }
}

/// A file in the profile folder that could not be used.
public struct ProfileFileProblem: Hashable, Sendable {
    public var file: URL
    public var reason: String

    public init(file: URL, reason: String) {
        self.file = file
        self.reason = reason
    }
}

/// The result of scanning the folder: the usable profiles and the files that were skipped.
public struct ProfileListing: Sendable {
    public var summaries: [ProfileSummary]
    public var problems: [ProfileFileProblem]

    public init(summaries: [ProfileSummary] = [], problems: [ProfileFileProblem] = []) {
        self.summaries = summaries
        self.problems = problems
    }
}

public enum ProfileStoreError: Error, LocalizedError, Equatable {
    /// No file for this profile id.
    case notFound(UUID)
    /// The name is empty after trimming.
    case invalidName
    /// The data is not a readable profile. `source` is a file name or a description of where it came from.
    case corrupt(source: String, reason: String)
    /// The data was written by a newer schema than this build understands.
    case unsupportedSchema(found: Int, supported: Int)
    /// `Profile.validate()` found problems (used by import).
    case invalidProfile([String])

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "There is no saved profile with id \(id.uuidString)."
        case .invalidName:
            return "A profile needs a name."
        case .corrupt(let source, let reason):
            return "\(source) is not a valid profile: \(reason)"
        case .unsupportedSchema(let found, let supported):
            if found > supported {
                return "This profile was saved by a newer version of Windows Manager (schema \(found)); this version reads up to schema \(supported). Update the app to open it."
            }
            return "Profile schema version \(found) is not valid; the oldest supported version is 1."
        case .invalidProfile(let problems):
            return "The profile has problems: " + problems.joined(separator: " ")
        }
    }
}

public final class ProfileStore: @unchecked Sendable {
    /// `~/Library/Application Support/WindowsManager/Profiles/`.
    /// `WM_PROFILES_DIR` overrides it (UX fixtures, smoke tests).
    public static var defaultFolder: URL {
        if let dir = ProcessInfo.processInfo.environment["WM_PROFILES_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("WindowsManager", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
    }

    public let folder: URL
    /// Where `delete` moves files.
    public var trashFolder: URL { folder.appendingPathComponent("Trash", isDirectory: true) }

    private let fileManager: FileManager
    // Recursive because rename/duplicate call load and save while holding the lock.
    private let lock = NSRecursiveLock()
    private var storedProblems: [ProfileFileProblem] = []

    /// The folder is created on the first write, so a store for a folder that does not exist yet lists nothing.
    public init(folder: URL? = nil, fileManager: FileManager = .default) {
        self.folder = folder ?? Self.defaultFolder
        self.fileManager = fileManager
    }

    /// The URL of the file that holds a profile.
    public func fileURL(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    /// The files the last `list()` / `scan()` skipped, with the reason for each.
    public var lastProblems: [ProfileFileProblem] {
        lock.lock(); defer { lock.unlock() }
        return storedProblems
    }

    // MARK: Listing

    /// Every usable profile, sorted by name. Unreadable files are skipped; see `lastProblems` or `scan()`.
    public func list() -> [ProfileSummary] {
        scan().summaries
    }

    /// Like `list()`, and also reports each skipped file. Never throws and never crashes on bad files.
    public func scan() -> ProfileListing {
        lock.lock(); defer { lock.unlock() }

        var summaries: [ProfileSummary] = []
        var problems: [ProfileFileProblem] = []

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: [.skipsHiddenFiles])
        } catch {
            storedProblems = []
            // A folder that does not exist yet is simply an empty store.
            if fileManager.fileExists(atPath: folder.path) {
                let problem = ProfileFileProblem(file: folder, reason: error.localizedDescription)
                storedProblems = [problem]
                return ProfileListing(summaries: [], problems: [problem])
            }
            return ProfileListing()
        }

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "json" {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }
            do {
                let profile = try readProfile(at: url)
                let stem = url.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: stem) == profile.id else {
                    throw ProfileStoreError.corrupt(source: url.lastPathComponent,
                                                    reason: "the file name does not match the profile id \(profile.id.uuidString)")
                }
                summaries.append(ProfileSummary(profile))
            } catch {
                problems.append(ProfileFileProblem(file: url, reason: Self.reason(for: error)))
            }
        }

        summaries.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        storedProblems = problems
        return ProfileListing(summaries: summaries, problems: problems)
    }

    // MARK: CRUD

    public func load(_ id: UUID) throws -> Profile {
        lock.lock(); defer { lock.unlock() }
        return try loadLocked(id)
    }

    /// Writes the profile (schema version and `updatedAt` are set here) and returns what was stored.
    /// Dates are kept to the millisecond on disk, so the result is exactly what a later `load` returns.
    @discardableResult
    public func save(_ profile: Profile) throws -> Profile {
        lock.lock(); defer { lock.unlock() }
        var saved = profile
        saved.schemaVersion = Profile.currentSchemaVersion
        saved.updatedAt = Date()
        return try write(saved)
    }

    /// Moves the profile file to `Trash/` instead of deleting it. Returns the new location.
    @discardableResult
    public func delete(_ id: UUID) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let source = fileURL(for: id)
        guard fileManager.fileExists(atPath: source.path) else { throw ProfileStoreError.notFound(id) }
        try fileManager.createDirectory(at: trashFolder, withIntermediateDirectories: true)

        var target = trashFolder.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: target.path) {
            // The same profile was trashed before: keep both.
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            target = trashFolder.appendingPathComponent("\(id.uuidString) \(stamp).json")
            while fileManager.fileExists(atPath: target.path) {
                target = trashFolder.appendingPathComponent("\(id.uuidString) \(stamp) \(UUID().uuidString.prefix(8)).json")
            }
        }
        try fileManager.moveItem(at: source, to: target)
        return target
    }

    /// Writes `profile` back exactly as given (same id, name, dates and hotkey). Used to undo a delete.
    /// Throws when a file with the same id is already in the store (it is never overwritten).
    @discardableResult
    public func restore(_ profile: Profile) throws -> Profile {
        lock.lock(); defer { lock.unlock() }
        guard !fileManager.fileExists(atPath: fileURL(for: profile.id).path) else {
            throw ProfileStoreError.invalidProfile(["A saved profile with id \(profile.id.uuidString) already exists."])
        }
        return try write(profile)
    }

    @discardableResult
    public func rename(_ id: UUID, to name: String) throws -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileStoreError.invalidName }
        lock.lock(); defer { lock.unlock() }
        var profile = try loadLocked(id)
        profile.name = trimmed
        return try save(profile)
    }

    /// Saves a copy under a new id. The copy has no hotkey, because a hotkey belongs to one profile.
    /// The default name is "<name> copy".
    @discardableResult
    public func duplicate(_ id: UUID, name: String? = nil) throws -> Profile {
        lock.lock(); defer { lock.unlock() }
        var copy = try loadLocked(id)
        let requested = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.id = UUID()
        copy.name = (requested?.isEmpty == false ? requested : nil) ?? "\(copy.name) copy"
        copy.createdAt = Date()
        copy.options.hotkey = nil
        return try save(copy)
    }

    // MARK: Export and import

    /// Writes the profile as a standalone JSON file at `url` (replacing a file that is already there).
    public func export(_ id: UUID, to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let profile = try loadLocked(id)
        try writeAtomically(try Self.encode(profile), to: url)
    }

    /// Reads a profile file from anywhere and stores it. A profile whose id is already in the store gets a
    /// new id (and loses its hotkey) so nothing is overwritten. Dates are kept as they were in the file.
    @discardableResult
    public func importProfile(from url: URL) throws -> Profile {
        lock.lock(); defer { lock.unlock() }
        let data = try Data(contentsOf: url)
        var profile = try Self.decode(data, source: url.lastPathComponent)
        let problems = profile.validate()
        guard problems.isEmpty else { throw ProfileStoreError.invalidProfile(problems) }
        if fileManager.fileExists(atPath: fileURL(for: profile.id).path) {
            profile.id = UUID()
            profile.options.hotkey = nil
        }
        return try write(profile)
    }

    // MARK: Encoding and migration

    /// Pretty printed JSON, sorted keys, ISO-8601 dates with milliseconds. Same bytes as the stored files.
    public static func encode(_ profile: Profile) throws -> Data {
        try makeEncoder().encode(profile)
    }

    /// Reads a profile from JSON of any supported schema version (older ones are migrated first).
    /// `source` names the data in error messages.
    public static func decode(_ data: Data, source: String = "The data") throws -> Profile {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProfileStoreError.corrupt(source: source, reason: "it is not JSON (\(error.localizedDescription))")
        }
        guard let json = object as? [String: Any] else {
            throw ProfileStoreError.corrupt(source: source, reason: "the top level is not a JSON object")
        }
        guard let version = (json["schemaVersion"] as? NSNumber)?.intValue else {
            throw ProfileStoreError.corrupt(source: source, reason: "schemaVersion is missing")
        }

        // Only a migrated document is re-serialized; a current one is decoded from the original bytes.
        var payload = data
        if version != Profile.currentSchemaVersion {
            let migrated = try migrate(json: json, from: version)
            do {
                payload = try JSONSerialization.data(withJSONObject: migrated)
            } catch {
                throw ProfileStoreError.corrupt(source: source, reason: "the migrated data could not be written (\(error.localizedDescription))")
            }
        }
        do {
            return try makeDecoder().decode(Profile.self, from: payload)
        } catch let error as DecodingError {
            throw ProfileStoreError.corrupt(source: source, reason: describe(error))
        }
    }

    /// Schema migration hook: turns JSON written with schema `version` into JSON of the current schema.
    /// Only version 1 exists, so there is nothing to convert yet; a newer or invalid version throws.
    /// To add schema 2, bump `Profile.currentSchemaVersion` and add a conversion step below.
    public static func migrate(json: [String: Any], from version: Int) throws -> [String: Any] {
        guard version >= 1, version <= Profile.currentSchemaVersion else {
            throw ProfileStoreError.unsupportedSchema(found: version, supported: Profile.currentSchemaVersion)
        }
        var result = json
        // Schema 1 is the only one, so there is nothing to convert yet. Add one step per new schema, oldest first:
        //   if version < 2 { result = convertVersion1To2(result) }
        result["schemaVersion"] = Profile.currentSchemaVersion
        return result
    }

    // MARK: Private

    private func loadLocked(_ id: UUID) throws -> Profile {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { throw ProfileStoreError.notFound(id) }
        return try readProfile(at: url)
    }

    private func readProfile(at url: URL) throws -> Profile {
        try Self.decode(try Data(contentsOf: url), source: url.lastPathComponent)
    }

    /// Writes the profile file and returns the profile as it reads back from those bytes.
    private func write(_ profile: Profile) throws -> Profile {
        let data = try Self.encode(profile)
        try writeAtomically(data, to: fileURL(for: profile.id))
        return try Self.decode(data, source: fileURL(for: profile.id).lastPathComponent)
    }

    /// Writes next to the destination and then swaps the file in, so readers see the old or the new
    /// content, never a partial file. The temp file starts with a dot, which `scan` ignores.
    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    private static func reason(for error: Error) -> String {
        if case ProfileStoreError.corrupt(_, let reason) = error { return reason }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// ISO-8601 with milliseconds. The formatter cuts off extra digits instead of rounding, which would
    /// shift a date by 1 ms on every load and save (a parsed date is a hair below its millisecond).
    /// A quarter millisecond is added first, so the text is the nearest millisecond and stays stable.
    private static func isoString(_ date: Date) -> String {
        date.addingTimeInterval(0.00025).formatted(fractionalDates)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let text = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return text.isEmpty ? "" : String(text.drop(while: { $0 == "." })) + ": "
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(path(context))missing key \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return path(context) + context.debugDescription
        @unknown default:
            return error.localizedDescription
        }
    }

    private static let fractionalDates = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainDates = Date.ISO8601FormatStyle()

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoString(date))
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Accepts "2026-10-25T12:00:00.123Z" (what we write) and "2026-10-25T12:00:00Z" (hand-edited files).
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: fractionalDates) { return date }
            if let date = try? Date(text, strategy: plainDates) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "\(text) is not an ISO-8601 date"))
        }
        return decoder
    }
}
