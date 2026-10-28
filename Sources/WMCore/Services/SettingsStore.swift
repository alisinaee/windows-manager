import Foundation

// One typed store over the app's UserDefaults suite (P6.89). The CLI and the tests read and write the same
// keys the app uses. Compound JSON settings (snap, Space guard) are exposed field by field as dotted keys
// ("snap.gap"), written back into the same JSON blob the app reads, so unknown fields are kept.

public enum SettingValue: Equatable, Sendable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public var description: String {
        switch self {
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return v
        }
    }

    /// A JSON-friendly value for the CLI envelope.
    public var jsonObject: Any {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        }
    }
}

public struct SettingDefinition: Sendable {
    public enum Kind: Sendable, Equatable {
        case bool
        case int(ClosedRange<Int>)
        case double(ClosedRange<Double>)
        case choice([String])

        public var name: String {
            switch self {
            case .bool: return "bool"
            case .int: return "int"
            case .double: return "double"
            case .choice: return "choice"
            }
        }
    }

    public let key: String
    public let kind: Kind
    public let defaultValue: SettingValue
    public let summary: String
    /// UserDefaults key that holds the value (or the JSON blob when `field` is set).
    let storageKey: String
    /// Field inside a JSON blob stored as Data under `storageKey`.
    let field: String?
}

public struct SettingEntry: Equatable, Sendable {
    public let key: String
    public let value: SettingValue
    public let defaultValue: SettingValue
    public let isDefault: Bool
    public let kind: String
    public let summary: String
}

/// Grid overlay of one monitor in the Studio. Same JSON shape the app stores.
public struct MonitorGridSetting: Codable, Equatable, Sendable {
    public var isOn: Bool
    public var spec: GridSpec

    public init(isOn: Bool = false, spec: GridSpec = .medium) {
        self.isOn = isOn
        self.spec = spec
    }
}

public final class SettingsStore: @unchecked Sendable {
    public static let gridsStorageKey = "studio.builder.monitorGrids"

    private let defaults: UserDefaults
    private let lock = NSLock()

    /// - Parameter defaults: the suite to use; tests pass a throwaway suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// - Parameter suiteName: a UserDefaults suite (domain); nil is the standard domain.
    public convenience init(suiteName: String?) throws {
        guard let name = suiteName else { self.init(defaults: .standard); return }
        guard let suite = UserDefaults(suiteName: name) else { throw ServiceError.invalid("Cannot open settings domain \(name).") }
        self.init(defaults: suite)
    }

    // MARK: Definitions

    private static func def(_ key: String, _ kind: SettingDefinition.Kind, _ value: SettingValue, _ summary: String,
                            storage: String? = nil, field: String? = nil) -> SettingDefinition {
        SettingDefinition(key: key, kind: kind, defaultValue: value, summary: summary, storageKey: storage ?? key, field: field)
    }

    public static let definitions: [SettingDefinition] = [
        def("debugMode", .bool, .bool(false), "Show the live Debug test panel."),
        def("debugLogEnabled", .bool, .bool(false), "Write the debug log."),
        def("onboardingCompleted", .bool, .bool(false), "Onboarding was finished."),
        def("virtualWorkspacesEnabled", .bool, .bool(false), "Virtual workspaces switch is on."),
        def("virtualWorkspacesNaturalSwipe", .bool, .bool(true), "Workspace swipe uses natural direction."),
        def("virtualWorkspacesFollowAppSwitch", .bool, .bool(true), "Switching to an app follows it to its workspace."),
        def("studioSidebarVisible", .bool, .bool(true), "Studio sidebar is shown."),
        def("studioSidebarWidth", .double(100...1000), .double(240), "Studio sidebar width in points."),
        def("studioInspectorCollapsed", .bool, .bool(false), "Studio details panel is minimized."),
        def("studioInspectorHeight", .double(50...2000), .double(150), "Studio details panel height."),
        def("studioInspectorWidth", .double(50...2000), .double(260), "Studio details panel width."),
        def("snap.enabled", .bool, .bool(true), "Zone snapping while dragging windows.",
            storage: "snapSettings", field: "enabled"),
        def("snap.modifier", .choice(["option", "control", "command", "shift"]), .string("option"),
            "Modifier held to snap.", storage: "snapSettings", field: "modifier"),
        def("snap.minimumDragDistance", .double(0...500), .double(8), "Pointer travel before a press counts as a drag.",
            storage: "snapSettings", field: "minimumDragDistance"),
        def("snap.debounce", .double(0...5), .double(0.05), "Seconds in a zone before the highlight moves.",
            storage: "snapSettings", field: "debounce"),
        def("snap.gap", .double(0...200), .double(0), "Gap between snapped windows.",
            storage: "snapSettings", field: "gap"),
        def("spaceGuard.watchEnabled", .bool, .bool(false), "Watch the Space order for drift.",
            storage: "spaceGuard.settings", field: "watchEnabled"),
        def("spaceGuard.autoFix", .bool, .bool(false), "Ask for a fix when drift is confirmed.",
            storage: "spaceGuard.settings", field: "autoFix"),
    ]

    public static func definition(for key: String) throws -> SettingDefinition {
        guard let d = definitions.first(where: { $0.key == key }) else {
            throw ServiceError.notFound("Unknown setting \"\(key)\". Known: \(definitions.map(\.key).joined(separator: ", ")).")
        }
        return d
    }

    // MARK: Read

    public func get(_ key: String) throws -> SettingValue {
        let d = try Self.definition(for: key)
        lock.lock(); defer { lock.unlock() }
        return read(d)
    }

    public func list() -> [SettingEntry] {
        lock.lock(); defer { lock.unlock() }
        return Self.definitions.map { d in
            let v = read(d)
            return SettingEntry(key: d.key, value: v, defaultValue: d.defaultValue, isDefault: v == d.defaultValue,
                                kind: d.kind.name, summary: d.summary)
        }
    }

    // MARK: Write

    public func set(_ key: String, _ value: SettingValue) throws {
        let d = try Self.definition(for: key)
        let clean = try Self.validate(value, for: d)
        lock.lock(); defer { lock.unlock() }
        try write(d, clean)
    }

    /// Parses text ("true", "12", "0.5", "option") by the setting's type, then sets it.
    public func set(_ key: String, text: String) throws {
        let d = try Self.definition(for: key)
        try set(key, try Self.parse(text, for: d))
    }

    /// Removes the stored value so the default applies again.
    public func reset(_ key: String) throws {
        let d = try Self.definition(for: key)
        lock.lock(); defer { lock.unlock() }
        if let field = d.field {
            var dict = blob(d.storageKey)
            dict[field] = nil
            try storeBlob(dict, d.storageKey)
        } else {
            defaults.removeObject(forKey: d.storageKey)
        }
    }

    public func resetAll() throws {
        for d in Self.definitions { try reset(d.key) }
    }

    // MARK: Grids

    public func grids() -> [String: MonitorGridSetting] {
        lock.lock(); defer { lock.unlock() }
        return readGrids()
    }

    public func grid(display: String) -> MonitorGridSetting {
        grids()[display.uppercased()] ?? MonitorGridSetting()
    }

    public func setGrid(display: String, isOn: Bool? = nil, columns: Int? = nil, rows: Int? = nil) throws {
        let id = display.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !id.isEmpty else { throw ServiceError.invalid("Display id is empty.") }
        for (name, v) in [("columns", columns), ("rows", rows)] {
            if let v, !GridSpec.limits.contains(v) {
                throw ServiceError.invalid("Grid \(name) must be \(GridSpec.limits.lowerBound)-\(GridSpec.limits.upperBound), got \(v).")
            }
        }
        lock.lock(); defer { lock.unlock() }
        var all = readGrids()
        var g = all[id] ?? MonitorGridSetting()
        if let isOn { g.isOn = isOn }
        g.spec = GridSpec(columns: columns ?? g.spec.columns, rows: rows ?? g.spec.rows)
        all[id] = g
        try writeGrids(all)
    }

    public func resetGrid(display: String) throws {
        lock.lock(); defer { lock.unlock() }
        var all = readGrids()
        all[display.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()] = nil
        try writeGrids(all)
    }

    // MARK: Internals

    private func readGrids() -> [String: MonitorGridSetting] {
        defaults.data(forKey: Self.gridsStorageKey)
            .flatMap { try? JSONDecoder().decode([String: MonitorGridSetting].self, from: $0) } ?? [:]
    }

    private func writeGrids(_ grids: [String: MonitorGridSetting]) throws {
        do { defaults.set(try JSONEncoder().encode(grids), forKey: Self.gridsStorageKey) } catch { throw ServiceError.wrap(error) }
    }

    private func blob(_ storageKey: String) -> [String: Any] {
        guard let data = defaults.data(forKey: storageKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func storeBlob(_ dict: [String: Any], _ storageKey: String) throws {
        if dict.isEmpty { defaults.removeObject(forKey: storageKey); return }
        do { defaults.set(try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]), forKey: storageKey) }
        catch { throw ServiceError.wrap(error) }
    }

    private func read(_ d: SettingDefinition) -> SettingValue {
        let raw: Any?
        if let field = d.field { raw = blob(d.storageKey)[field] } else { raw = defaults.object(forKey: d.storageKey) }
        guard let raw else { return d.defaultValue }
        switch d.kind {
        case .bool:
            if let n = raw as? NSNumber { return .bool(n.boolValue) }
        case .int:
            if let n = raw as? NSNumber { return .int(n.intValue) }
        case .double:
            if let n = raw as? NSNumber { return .double(n.doubleValue) }
        case .choice(let options):
            if let s = raw as? String, options.contains(s) { return .string(s) }
        }
        return d.defaultValue
    }

    private func write(_ d: SettingDefinition, _ value: SettingValue) throws {
        if let field = d.field {
            var dict = blob(d.storageKey)
            dict[field] = value.jsonObject
            try storeBlob(dict, d.storageKey)
        } else {
            defaults.set(value.jsonObject, forKey: d.storageKey)
        }
    }

    static func validate(_ value: SettingValue, for d: SettingDefinition) throws -> SettingValue {
        func bad(_ why: String) -> ServiceError { .invalid("\(d.key): \(why)") }
        switch (d.kind, value) {
        case (.bool, .bool): return value
        case (.int(let r), .int(let v)):
            guard r.contains(v) else { throw bad("must be \(r.lowerBound)-\(r.upperBound), got \(v)") }
            return value
        case (.int(let r), .double(let v)) where v == v.rounded() && v.isFinite:
            guard r.contains(Int(v)) else { throw bad("must be \(r.lowerBound)-\(r.upperBound), got \(Int(v))") }
            return .int(Int(v))
        case (.double(let r), .double(let v)):
            guard v.isFinite, r.contains(v) else { throw bad("must be \(r.lowerBound)-\(r.upperBound), got \(v)") }
            return value
        case (.double(let r), .int(let v)):
            guard r.contains(Double(v)) else { throw bad("must be \(r.lowerBound)-\(r.upperBound), got \(v)") }
            return .double(Double(v))
        case (.choice(let options), .string(let s)):
            guard options.contains(s) else { throw bad("must be one of \(options.joined(separator: ", ")), got \(s)") }
            return value
        default:
            throw bad("expected a \(d.kind.name) value")
        }
    }

    static func parse(_ text: String, for d: SettingDefinition) throws -> SettingValue {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch d.kind {
        case .bool:
            switch t.lowercased() {
            case "true", "on", "yes", "1": return .bool(true)
            case "false", "off", "no", "0": return .bool(false)
            default: throw ServiceError.invalid("\(d.key): expected true or false, got \"\(t)\"")
            }
        case .int:
            guard let v = Int(t) else { throw ServiceError.invalid("\(d.key): expected a whole number, got \"\(t)\"") }
            return .int(v)
        case .double:
            guard let v = Double(t) else { throw ServiceError.invalid("\(d.key): expected a number, got \"\(t)\"") }
            return .double(v)
        case .choice:
            return .string(t)
        }
    }
}
