import Foundation

// Per-app window rules (phase P6.1). Only stored and edited for now; the restore planner does not read them yet.
// Saved as one JSON file next to the Profiles folder: <WindowsManager>/WindowRules.json.

public enum WindowRuleAction: Codable, Hashable, Sendable {
    /// Leave this app's windows alone.
    case ignore
    /// Always bring this app's windows back, even when a profile would skip them.
    case alwaysRestore
    /// Keep this app's windows on the display with this UUID.
    case pinToDisplay(uuid: String)

    private enum CodingKeys: String, CodingKey { case type, uuid }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "ignore": self = .ignore
        case "alwaysRestore": self = .alwaysRestore
        case "pinToDisplay": self = .pinToDisplay(uuid: try c.decode(String.self, forKey: .uuid))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown rule action \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ignore: try c.encode("ignore", forKey: .type)
        case .alwaysRestore: try c.encode("alwaysRestore", forKey: .type)
        case .pinToDisplay(let uuid):
            try c.encode("pinToDisplay", forKey: .type)
            try c.encode(uuid, forKey: .uuid)
        }
    }
}

public struct WindowRule: Codable, Hashable, Sendable, Identifiable {
    public var bundleID: String
    public var action: WindowRuleAction
    public var id: String { bundleID }

    public init(bundleID: String, action: WindowRuleAction) {
        self.bundleID = bundleID
        self.action = action
    }
}

public struct WindowRules: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int = WindowRules.currentSchemaVersion
    public var rules: [WindowRule] = []

    public init(rules: [WindowRule] = []) {
        self.rules = rules
    }

    public func rule(for bundleID: String) -> WindowRule? {
        rules.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Adds the rule, or replaces the existing rule for the same app (bundle id compared ignoring case).
    public mutating func set(_ rule: WindowRule) {
        let id = rule.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        var clean = rule
        clean.bundleID = id
        if let index = rules.firstIndex(where: { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame }) {
            rules[index] = clean
        } else {
            rules.append(clean)
        }
    }

    public mutating func remove(bundleID: String) {
        rules.removeAll { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

public final class WindowRulesStore: @unchecked Sendable {
    /// `~/Library/Application Support/WindowsManager/WindowRules.json`, next to the Profiles folder.
    public static var defaultFile: URL {
        ProfileStore.defaultFolder.deletingLastPathComponent().appendingPathComponent("WindowRules.json")
    }

    public let file: URL
    private let lock = NSLock()

    public init(file: URL? = nil) {
        self.file = file ?? Self.defaultFile
    }

    /// A missing or unreadable file reads as no rules.
    public func load() -> WindowRules {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file),
              let rules = try? JSONDecoder().decode(WindowRules.self, from: data) else { return WindowRules() }
        return rules
    }

    public func save(_ rules: WindowRules) throws {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
