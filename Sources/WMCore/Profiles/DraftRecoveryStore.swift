import Foundation

// Crash recovery for Profile Studio drafts (P9.14). The Studio writes the open draft here a moment after every
// change, as `<folder>/<profileID>.draft.json`, and deletes it on Save or Discard. The real profile file is never
// touched. Pure file logic: the app decides when to call it.

/// One recovered draft: the profile as the user left it, and when and from what it was written.
public struct RecoveredDraft: Equatable, Sendable {
    public var profile: Profile
    /// `updatedAt` of the saved profile this draft started from; nil for a draft of a never-saved profile.
    public var baseUpdatedAt: Date?
    public var savedAt: Date

    public init(profile: Profile, baseUpdatedAt: Date?, savedAt: Date) {
        self.profile = profile
        self.baseUpdatedAt = baseUpdatedAt
        self.savedAt = savedAt
    }
}

public final class DraftRecoveryStore: @unchecked Sendable {
    /// `~/Library/Application Support/WindowsManager/Drafts/` (next to the Profiles folder).
    public static var defaultFolder: URL {
        ProfileStore.defaultFolder.deletingLastPathComponent().appendingPathComponent("Drafts", isDirectory: true)
    }

    public let folder: URL

    public init(folder: URL? = nil) {
        self.folder = folder ?? Self.defaultFolder
    }

    public func file(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).draft.json", isDirectory: false)
    }

    // MARK: Write / read / delete

    /// Writes the draft atomically (temp file, then swap). Safe to call from any thread.
    public func write(_ profile: Profile, baseUpdatedAt: Date?, savedAt: Date = Date()) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let envelope = Envelope(savedAt: savedAt, baseUpdatedAt: baseUpdatedAt, profile: profile)
        let data = try Self.makeEncoder().encode(envelope)
        try data.write(to: file(for: profile.id), options: .atomic)
    }

    /// The draft for `id`; nil when there is none or the file cannot be read.
    public func read(_ id: UUID) -> RecoveredDraft? {
        guard let data = try? Data(contentsOf: file(for: id)),
              let envelope = try? Self.makeDecoder().decode(Envelope.self, from: data) else { return nil }
        return RecoveredDraft(profile: envelope.profile, baseUpdatedAt: envelope.baseUpdatedAt, savedAt: envelope.savedAt)
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }

    /// The ids that have a draft file, in no particular order.
    public func draftIDs() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".draft.json") else { return nil }
            return UUID(uuidString: String(name.dropLast(".draft.json".count)))
        }
    }

    // MARK: Decisions

    /// True when the draft is worth offering back: it is not the same as what is saved (or nothing is saved).
    public static func differs(_ draft: Profile, from saved: Profile?) -> Bool {
        guard let saved else { return true }
        return draft != saved
    }

    /// True when the saved profile was changed after the draft started.
    public static func isStale(_ draft: RecoveredDraft, savedUpdatedAt: Date?) -> Bool {
        guard let savedUpdatedAt, let base = draft.baseUpdatedAt else { return false }
        return savedUpdatedAt > base
    }

    /// The draft for `id` when it differs from `saved`; a draft that equals the saved profile is deleted.
    public func recoverable(_ id: UUID, saved: Profile?) -> RecoveredDraft? {
        guard let draft = read(id) else { return nil }
        guard Self.differs(draft.profile, from: saved) else { delete(id); return nil }
        return draft
    }

    // MARK: Format

    private struct Envelope: Codable {
        var savedAt: Date
        var baseUpdatedAt: Date?
        var profile: Profile
    }

    private static let fractionalDates = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainDates = Date.ISO8601FormatStyle()

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(fractionalDates))
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
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
