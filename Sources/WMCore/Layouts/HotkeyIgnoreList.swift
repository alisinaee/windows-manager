import Foundation

// Per-app ignore list for the global shortcuts. While a listed app is frontmost, the shortcuts do nothing.
// Stored as an array of bundle ids under `hotkeyIgnoredApps` in UserDefaults.

public struct HotkeyIgnoreList: Equatable, Sendable {
    public static let defaultsKey = "hotkeyIgnoredApps"

    /// Bundle ids in the order they were added, without duplicates.
    public private(set) var bundleIDs: [String]

    public init(bundleIDs: [String] = []) {
        self.bundleIDs = []
        for id in bundleIDs { add(id) }
    }

    /// True when shortcuts must be suppressed for `bundleID` (nil, such as an unnamed process, never matches).
    public func contains(_ bundleID: String?) -> Bool {
        guard let id = Self.normalized(bundleID) else { return false }
        return bundleIDs.contains(id)
    }

    /// Adds a bundle id. Blank ids and duplicates are ignored. Returns true when the list changed.
    @discardableResult
    public mutating func add(_ bundleID: String?) -> Bool {
        guard let id = Self.normalized(bundleID), !bundleIDs.contains(id) else { return false }
        bundleIDs.append(id)
        return true
    }

    /// Removes a bundle id. Returns true when the list changed.
    @discardableResult
    public mutating func remove(_ bundleID: String) -> Bool {
        let before = bundleIDs.count
        bundleIDs.removeAll { $0 == bundleID }
        return bundleIDs.count != before
    }

    /// Loads the list from `defaults`. Missing or malformed values give an empty list.
    public static func load(from defaults: UserDefaults = .standard) -> HotkeyIgnoreList {
        HotkeyIgnoreList(bundleIDs: defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    /// Writes the list to `defaults`.
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(bundleIDs, forKey: Self.defaultsKey)
    }

    private static func normalized(_ bundleID: String?) -> String? {
        guard let trimmed = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
