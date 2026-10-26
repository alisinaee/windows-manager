import Foundation

// Auto profile (P3.7): run a saved profile by itself when the monitor set changes, the Mac wakes or the
// screen is unlocked. This file holds the settings, the pure decision and a small JSON store. The app side
// (AutoProfileController) feeds it events from DisplayWatcher and runs the chosen profile.

/// The things that can start an automatic run.
public enum AutoProfileEvent: String, Codable, Hashable, Sendable, CaseIterable {
    case monitorChange
    case wake
    case unlock
}

/// Which events may start a run. All are on by default; the feature itself is off until the user enables it.
public struct AutoProfileTriggers: Codable, Hashable, Sendable {
    public var monitorChange: Bool
    public var wake: Bool
    public var unlock: Bool

    public init(monitorChange: Bool = true, wake: Bool = true, unlock: Bool = true) {
        self.monitorChange = monitorChange
        self.wake = wake
        self.unlock = unlock
    }

    public func allows(_ event: AutoProfileEvent) -> Bool {
        switch event {
        case .monitorChange: return monitorChange
        case .wake: return wake
        case .unlock: return unlock
        }
    }
}

/// A saved profile and the monitor set it was captured on, as the decider needs them.
public struct AutoProfileCandidate: Hashable, Sendable {
    public var id: UUID
    public var monitorSetKey: String

    public init(id: UUID, monitorSetKey: String) {
        self.id = id
        self.monitorSetKey = monitorSetKey
    }
}

/// User settings for automatic runs. Stored as JSON by `AutoProfileStore`.
public struct AutoProfileSettings: Codable, Hashable, Sendable {
    /// Off by default: nothing runs on its own until the user turns it on.
    public var enabled: Bool
    public var triggers: AutoProfileTriggers
    /// Explicit choice per monitor set: `DisplayMap.monitorSetKey` -> profile id. Wins over the captured key.
    public var mapping: [String: UUID]
    /// Quiet time after an event before the decision is made, so the display settles first.
    public var delaySeconds: Double
    /// Minimum time between two automatic runs.
    public var cooldownSeconds: Double

    public static let defaultDelaySeconds: Double = 3
    public static let defaultCooldownSeconds: Double = 60

    public init(enabled: Bool = false, triggers: AutoProfileTriggers = AutoProfileTriggers(),
                mapping: [String: UUID] = [:], delaySeconds: Double = defaultDelaySeconds,
                cooldownSeconds: Double = defaultCooldownSeconds) {
        self.enabled = enabled
        self.triggers = triggers
        self.mapping = mapping
        self.delaySeconds = max(0, delaySeconds)
        self.cooldownSeconds = max(0, cooldownSeconds)
    }
}

/// The pure rule: which profile (if any) should run for this event.
public enum AutoProfileDecider {
    /// - Parameters:
    ///   - event: what just happened (after the burst was collapsed by the caller).
    ///   - currentMonitorSetKey: `DisplayMap.monitorSetKey` of the monitors connected now.
    ///   - settings: the user's settings.
    ///   - savedProfiles: every saved profile with the monitor set it was captured on. A chosen id must be in
    ///     this list, so a deleted profile never runs.
    ///   - lastRun: when the last automatic run started, or nil.
    ///   - now: the current time.
    /// - Returns: the id of the profile to run, or nil when nothing should run.
    ///
    /// Rules, in order: the feature is on; the event's trigger is on; the last automatic run is at least
    /// `cooldownSeconds` ago; the explicit mapping for this monitor set wins, otherwise the first saved profile
    /// (in the given order) captured on this monitor set. Callers collapse one burst of events into one call,
    /// so a burst can never fire twice.
    public static func decide(event: AutoProfileEvent, currentMonitorSetKey: String, settings: AutoProfileSettings,
                              savedProfiles: [AutoProfileCandidate] = [], lastRun: Date?, now: Date) -> UUID? {
        guard settings.enabled, settings.triggers.allows(event) else { return nil }
        if let lastRun, now.timeIntervalSince(lastRun) < settings.cooldownSeconds { return nil }
        let saved = Set(savedProfiles.map(\.id))
        if let mapped = settings.mapping[currentMonitorSetKey] {
            return saved.contains(mapped) ? mapped : nil
        }
        return savedProfiles.first { $0.monitorSetKey == currentMonitorSetKey }?.id
    }
}

/// Reads and writes `AutoProfileSettings` as one JSON file. A missing or unreadable file gives the defaults,
/// so a damaged file never blocks the app.
public final class AutoProfileStore: @unchecked Sendable {
    /// `~/Library/Application Support/WindowsManager/auto-profile.json`.
    public static var defaultFileURL: URL {
        ProfileStore.defaultFolder.deletingLastPathComponent().appendingPathComponent("auto-profile.json")
    }

    public let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.fileManager = fileManager
    }

    public func load() -> AutoProfileSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(AutoProfileSettings.self, from: data) else {
            return AutoProfileSettings()
        }
        return settings
    }

    public func save(_ settings: AutoProfileSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
