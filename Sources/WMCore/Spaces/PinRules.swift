import Foundation

// Pin rules (phase P3.5): "when a window of this app is created, move it to that Desktop".
// This file holds the rule model, the JSON store and the pure matcher. The watcher that applies the
// decisions with SpaceMover.moveAsync lives in the app target (Pins/PinWatcher.swift).
// Existing per-app rules (WindowRules.swift: ignore, alwaysRestore, pinToDisplay) are a separate store and are not changed.

/// Where a pinned window goes.
public enum PinTarget: Codable, Hashable, Sendable {
    /// "Desktop N" (1-based, full-screen Spaces not counted) on the display with this identifier.
    /// The identifier is the display UUID, as `DisplayIdentity.uuid` reports it.
    case desktopIndex(number: Int, displayUUID: String)
    /// A Desktop by its SkyLight Space id.
    case spaceID(UInt64)

    private enum CodingKeys: String, CodingKey { case type, number, displayUUID, spaceID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "desktopIndex":
            self = .desktopIndex(number: try c.decode(Int.self, forKey: .number),
                                 displayUUID: try c.decode(String.self, forKey: .displayUUID))
        case "spaceID":
            self = .spaceID(try c.decode(UInt64.self, forKey: .spaceID))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown pin target \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .desktopIndex(let number, let uuid):
            try c.encode("desktopIndex", forKey: .type)
            try c.encode(number, forKey: .number)
            try c.encode(uuid, forKey: .displayUUID)
        case .spaceID(let id):
            try c.encode("spaceID", forKey: .type)
            try c.encode(id, forKey: .spaceID)
        }
    }
}

/// One pin rule. `titleContains` nil means every window of the app.
public struct PinRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var bundleID: String
    public var titleContains: String?
    public var target: PinTarget

    public init(id: UUID = UUID(), bundleID: String, titleContains: String? = nil, target: PinTarget) {
        self.id = id
        self.bundleID = bundleID
        self.titleContains = titleContains
        self.target = target
    }

    /// Bundle id compared ignoring case; a title filter is a case- and diacritic-insensitive substring test.
    /// A rule with a title filter does not match a window whose title is not known yet.
    public func matches(bundleID windowBundleID: String, title: String?) -> Bool {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.caseInsensitiveCompare(windowBundleID) == .orderedSame else { return false }
        guard let filter = titleContains?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty else {
            return true
        }
        guard let title else { return false }
        return title.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// The file the rules are saved in: `{"schemaVersion":1,"rules":[...]}`.
public struct PinRulesFile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int = PinRulesFile.currentSchemaVersion
    public var rules: [PinRule]

    public init(rules: [PinRule] = []) {
        self.rules = rules
    }
}

/// Reads and writes the pin rules. A missing or unreadable file reads as no rules.
public final class PinRulesStore: @unchecked Sendable {
    /// The same folder as the profiles' parent: `~/Library/Application Support/WindowsManager`.
    public static var defaultDirectory: URL {
        ProfileStore.defaultFolder.deletingLastPathComponent()
    }

    public let file: URL
    private let lock = NSLock()

    /// - Parameter directory: the folder that holds `PinRules.json`; tests pass a temporary folder.
    public init(directory: URL? = nil) {
        self.file = (directory ?? Self.defaultDirectory).appendingPathComponent("PinRules.json")
    }

    public func load() -> [PinRule] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(PinRulesFile.self, from: data) else { return [] }
        return stored.rules
    }

    /// Writes the whole list atomically (the file is replaced in one step).
    public func save(_ rules: [PinRule]) throws {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(PinRulesFile(rules: rules))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}

/// A window that was just created, as the watcher sees it.
public struct PinWindowInfo: Equatable, Sendable {
    public var bundleID: String
    public var title: String?
    public var windowID: UInt32
    /// The one Space the window is on; nil when it is on no Space or on several (set to all Desktops).
    public var currentSpaceID: UInt64?

    public init(bundleID: String, title: String?, windowID: UInt32, currentSpaceID: UInt64?) {
        self.bundleID = bundleID
        self.title = title
        self.windowID = windowID
        self.currentSpaceID = currentSpaceID
    }
}

/// What the matcher must know about earlier moves. The clock is passed in, so tests control time.
public struct PinHistory: Equatable, Sendable {
    /// The time "now" for the quiet-period check.
    public var now: Date
    /// Seconds after a manual move during which the window is left where the user put it.
    public var manualQuietPeriod: TimeInterval
    /// Window id -> when the user last moved it by hand (not by a pin).
    public var manualMoveTimes: [UInt32: Date]
    /// Window ids that were already moved by a pin. Each window is pinned at most once.
    public var alreadyMoved: Set<UInt32>

    public init(now: Date = Date(), manualQuietPeriod: TimeInterval = 10,
                manualMoveTimes: [UInt32: Date] = [:], alreadyMoved: Set<UInt32> = []) {
        self.now = now
        self.manualQuietPeriod = manualQuietPeriod
        self.manualMoveTimes = manualMoveTimes
        self.alreadyMoved = alreadyMoved
    }

    /// True when the user moved this window by hand less than `manualQuietPeriod` seconds ago.
    public func isInQuietPeriod(_ windowID: UInt32) -> Bool {
        guard let moved = manualMoveTimes[windowID] else { return false }
        return now.timeIntervalSince(moved) < manualQuietPeriod
    }
}

/// Move one window from its Desktop to another.
public struct PinDecision: Equatable, Sendable {
    public var windowID: UInt32
    public var ruleID: UUID
    public var fromSpaceID: UInt64
    public var targetSpaceID: UInt64

    public init(windowID: UInt32, ruleID: UUID, fromSpaceID: UInt64, targetSpaceID: UInt64) {
        self.windowID = windowID
        self.ruleID = ruleID
        self.fromSpaceID = fromSpaceID
        self.targetSpaceID = targetSpaceID
    }
}

public enum PinRules {
    /// The Space id a target stands for, or nil when the Desktop does not exist (display unplugged, number too big).
    /// Desktops are counted in Mission Control order; full-screen Spaces are skipped.
    public static func targetSpaceID(for target: PinTarget, in spaces: [DisplaySpaces]) -> UInt64? {
        switch target {
        case .desktopIndex(let number, let uuid):
            guard number >= 1, let display = spaces.first(where: { $0.displayIdentifier == uuid }) else { return nil }
            let desktops = display.spaces.filter { $0.kind == .desktop }
            guard number <= desktops.count else { return nil }
            return desktops[number - 1].id
        case .spaceID(let id):
            return spaces.lazy.flatMap(\.spaces).first(where: { $0.id == id && $0.kind == .desktop })?.id
        }
    }

    /// Decides whether a newly created window should be moved, and where.
    ///
    /// Returns nil (leave the window alone) when:
    /// - the window was already moved by a pin, or the user moved it by hand within the quiet period;
    /// - the window is on no single Space, or its Space is not a Desktop (full-screen, Split View, system);
    /// - no rule matches (the first matching rule in `rules` wins);
    /// - the rule's Desktop does not exist, is not a Desktop, or the window is already on it.
    public static func decide(newWindow: PinWindowInfo, rules: [PinRule], spaces: [DisplaySpaces],
                              history: PinHistory = PinHistory()) -> PinDecision? {
        guard !history.alreadyMoved.contains(newWindow.windowID),
              !history.isInQuietPeriod(newWindow.windowID) else { return nil }
        guard let source = newWindow.currentSpaceID,
              let sourceSpace = spaces.lazy.flatMap(\.spaces).first(where: { $0.id == source }),
              sourceSpace.kind == .desktop else { return nil }
        guard let rule = rules.first(where: { $0.matches(bundleID: newWindow.bundleID, title: newWindow.title) }),
              let target = targetSpaceID(for: rule.target, in: spaces),
              target != source else { return nil }
        return PinDecision(windowID: newWindow.windowID, ruleID: rule.id, fromSpaceID: source, targetSpaceID: target)
    }
}
