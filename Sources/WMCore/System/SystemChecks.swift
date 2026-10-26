import Foundation

/// A snapshot of the macOS settings Windows Manager cares about. Plain values, so it can be shown in
/// the onboarding window, printed by a command line tool and compared in tests.
public struct SystemReport: Codable, Equatable {
    /// This process may use the Accessibility API (move and resize other apps' windows).
    public var accessibilityTrusted: Bool
    /// "Automatically rearrange Spaces based on most recent use" (Dock `mru-spaces`). macOS default: on.
    public var autoRearrangeSpaces: Bool
    /// "Displays have separate Spaces" (Spaces `spans-displays` is false). macOS default: on.
    public var displaysHaveSeparateSpaces: Bool
    /// Stage Manager is switched on (WindowManager `GloballyEnabled`). macOS default: off.
    public var stageManagerOn: Bool
    /// "When switching to an application, switch to a Space with open windows for the application"
    /// (global `AppleSpacesSwitchOnActivate`). macOS default: on.
    public var switchToSpaceWithOpenWindows: Bool
    /// For example "27.0.1".
    public var macOSVersion: String

    public init(
        accessibilityTrusted: Bool,
        autoRearrangeSpaces: Bool,
        displaysHaveSeparateSpaces: Bool,
        stageManagerOn: Bool,
        switchToSpaceWithOpenWindows: Bool,
        macOSVersion: String
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.autoRearrangeSpaces = autoRearrangeSpaces
        self.displaysHaveSeparateSpaces = displaysHaveSeparateSpaces
        self.stageManagerOn = stageManagerOn
        self.switchToSpaceWithOpenWindows = switchToSpaceWithOpenWindows
        self.macOSVersion = macOSVersion
    }
}

/// Read-only look at the system: Accessibility trust and a few preferences that change how Spaces
/// and windows behave. It never writes a preference; changing them is the user's decision.
public enum SystemChecks {
    /// Keys of the dictionary `make(from:)` reads. Most are the real preference keys; the other two are
    /// values `report()` computes itself.
    public enum Key {
        public static let accessibilityTrusted = "accessibilityTrusted"
        /// com.apple.dock
        public static let autoRearrangeSpaces = "mru-spaces"
        /// com.apple.spaces (true means ONE Space spans all displays, so "separate Spaces" is off)
        public static let spansDisplays = "spans-displays"
        /// com.apple.WindowManager
        public static let stageManager = "GloballyEnabled"
        /// NSGlobalDomain
        public static let switchToSpaceWithOpenWindows = "AppleSpacesSwitchOnActivate"
        public static let macOSVersion = "macOSVersion"
    }

    /// Reads the live system state.
    public static func report() -> SystemReport {
        var values: [String: Any?] = [:]
        values[Key.accessibilityTrusted] = AXPermission.isTrusted()
        values[Key.autoRearrangeSpaces] = preference(Key.autoRearrangeSpaces, domain: "com.apple.dock")
        values[Key.spansDisplays] = preference(Key.spansDisplays, domain: "com.apple.spaces")
        values[Key.stageManager] = preference(Key.stageManager, domain: "com.apple.WindowManager")
        values[Key.switchToSpaceWithOpenWindows] = preference(
            Key.switchToSpaceWithOpenWindows, domain: kCFPreferencesAnyApplication as String)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        values[Key.macOSVersion] = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return make(from: values)
    }

    /// Pure builder, used by `report()` and by tests. A missing (or `nil`, or `NSNull`) value means
    /// "the macOS default":
    /// auto-rearrange on, separate Spaces on, Stage Manager off, switch-to-Space on, Accessibility not
    /// trusted, version "unknown". Booleans may arrive as `Bool`, `NSNumber` or the strings "1"/"0"/"true"/"false".
    public static func make(from values: [String: Any?]) -> SystemReport {
        func value(_ key: String) -> Any? {
            guard let stored = values[key] else { return nil }
            return stored is NSNull ? nil : stored
        }
        func flag(_ key: String, default fallback: Bool) -> Bool {
            guard let raw = value(key) else { return fallback }
            if let number = raw as? NSNumber { return number.boolValue }
            if let text = raw as? String {
                switch text.trimmingCharacters(in: .whitespaces).lowercased() {
                case "1", "true", "yes": return true
                case "0", "false", "no": return false
                default: return fallback
                }
            }
            return fallback
        }
        let spansDisplays = flag(Key.spansDisplays, default: false)
        let version = (value(Key.macOSVersion) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        return SystemReport(
            accessibilityTrusted: flag(Key.accessibilityTrusted, default: false),
            autoRearrangeSpaces: flag(Key.autoRearrangeSpaces, default: true),
            displaysHaveSeparateSpaces: !spansDisplays,
            stageManagerOn: flag(Key.stageManager, default: false),
            switchToSpaceWithOpenWindows: flag(Key.switchToSpaceWithOpenWindows, default: true),
            macOSVersion: version
        )
    }

    /// One preference value, or nil when the key is not set. Read only.
    private static func preference(_ key: String, domain: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }
}
