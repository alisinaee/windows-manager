import Foundation

/// Pure rules for removing the hotkeys of deleted profiles. The app applies them through KeyboardShortcuts.
/// Profile hotkeys are named `profile.<uuid>` and stored in UserDefaults under `KeyboardShortcuts_profile.<uuid>`.
public enum HotkeyCleanup {
    /// Prefix of a profile hotkey name, as used by `KeyboardShortcuts.Name`.
    public static let profileNamePrefix = "profile."
    /// Prefix of the UserDefaults key KeyboardShortcuts writes for a profile hotkey.
    public static let profileDefaultsPrefix = "KeyboardShortcuts_profile."

    /// Profile ids that had a hotkey registered earlier but are no longer saved.
    public static func staleProfileIDs(registered: Set<UUID>, current: [UUID]) -> Set<UUID> {
        registered.subtracting(current)
    }

    /// UserDefaults keys of profile hotkeys whose profile is not in `current`, in sorted order.
    /// Keys outside the `KeyboardShortcuts_profile.` namespace are never returned.
    public static func staleDefaultsKeys(in keys: some Sequence<String>, current: [UUID]) -> [String] {
        let live = Set(current)
        return keys
            .filter { key in
                guard key.hasPrefix(profileDefaultsPrefix) else { return false }
                let suffix = String(key.dropFirst(profileDefaultsPrefix.count))
                guard let id = UUID(uuidString: suffix) else { return true }
                return !live.contains(id)
            }
            .sorted()
    }

    /// The KeyboardShortcuts name for a stale defaults key (`KeyboardShortcuts_profile.<x>` gives `profile.<x>`).
    public static func shortcutName(forDefaultsKey key: String) -> String? {
        guard key.hasPrefix("KeyboardShortcuts_") else { return nil }
        return String(key.dropFirst("KeyboardShortcuts_".count))
    }
}
