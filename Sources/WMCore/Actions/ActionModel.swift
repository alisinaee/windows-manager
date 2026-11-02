import Foundation

/// When a profile runs an action relative to the window restore.
public enum ActionPhase: String, Codable, Equatable, Sendable {
    case beforeRestore, afterRestore
}

/// A recorded list of UI steps a profile can run (open an app, press a button, run a command ...).
public struct ProfileAction: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var phase: ActionPhase
    public var steps: [ActionStep]
    public var enabled: Bool
    /// Seconds to wait before the first step starts (lets the restore settle). 0 = start at once.
    public var delayBefore: TimeInterval
    /// Seconds to pause between steps so the UI can follow.
    public var stepGap: TimeInterval

    public static let defaultStepGap: TimeInterval = 0.3

    public init(id: UUID = UUID(), name: String, phase: ActionPhase = .afterRestore,
                steps: [ActionStep] = [], enabled: Bool = true,
                delayBefore: TimeInterval = 0, stepGap: TimeInterval = ProfileAction.defaultStepGap) {
        self.id = id; self.name = name; self.phase = phase; self.steps = steps; self.enabled = enabled
        self.delayBefore = delayBefore; self.stepGap = stepGap
    }

    private enum CodingKeys: String, CodingKey { case id, name, phase, steps, enabled, delayBefore, stepGap }

    /// Files written before P9.8 have no delay keys: they load with no wait before and the default gap.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        phase = try c.decode(ActionPhase.self, forKey: .phase)
        steps = try c.decode([ActionStep].self, forKey: .steps)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        delayBefore = max(0, try c.decodeIfPresent(TimeInterval.self, forKey: .delayBefore) ?? 0)
        stepGap = max(0, try c.decodeIfPresent(TimeInterval.self, forKey: .stepGap) ?? Self.defaultStepGap)
    }

    /// Delay values are written only when they differ from the defaults, so old actions re-encode unchanged.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(phase, forKey: .phase)
        try c.encode(steps, forKey: .steps)
        try c.encode(enabled, forKey: .enabled)
        if delayBefore != 0 { try c.encode(delayBefore, forKey: .delayBefore) }
        if stepGap != Self.defaultStepGap { try c.encode(stepGap, forKey: .stepGap) }
    }
}

/// One AX element to find, described level by level from the app's windows downward.
public struct ElementLocator: Codable, Equatable, Sendable {
    public var bundleID: String
    public var path: [ElementMatcher]
    /// Position of the element in the tree: role + index among same-role siblings, from below the window down.
    /// Used when the labels no longer match (a label that changes with state).
    public var structural: [StructuralHop]?
    /// Which window the structural path starts in (index among the app's windows, and its title when it had one).
    public var windowIndex: Int?
    public var windowTitle: String?
    /// Which search goes first. nil = labels first, unless a matcher is marked volatile.
    public var match: MatchPreference?

    public init(bundleID: String, path: [ElementMatcher], structural: [StructuralHop]? = nil,
                windowIndex: Int? = nil, windowTitle: String? = nil, match: MatchPreference? = nil) {
        self.bundleID = bundleID; self.path = path; self.structural = structural
        self.windowIndex = windowIndex; self.windowTitle = windowTitle; self.match = match
    }

    /// True when the position search should run before the label search.
    public var structuralFirst: Bool {
        match == .position || (match == nil && path.contains { $0.volatile == true })
    }
}

/// Which way a locator is matched first.
public enum MatchPreference: String, Codable, Equatable, Sendable, CaseIterable {
    case label, position
}

/// One step down the tree: the `index`-th child with this role (counting only children with that role).
public struct StructuralHop: Codable, Equatable, Sendable {
    public var role: String
    public var index: Int
    public init(role: String, index: Int) { self.role = role; self.index = index }
}

/// Describes one element in the tree. Role/subrole/description are filters; identifier and title rank the
/// candidates: identifier match, then exact title, then case-insensitive "contains". `index` picks the n-th
/// candidate (0 based) of the best rank.
public struct ElementMatcher: Codable, Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var identifier: String?
    public var description: String?
    public var index: Int?
    /// The recorded text looks like an icon name (an SF Symbol such as power.circle.fill) that changes with the
    /// app's state, so the position search goes first.
    public var volatile: Bool?

    public init(role: String, subrole: String? = nil, title: String? = nil, identifier: String? = nil,
                description: String? = nil, index: Int? = nil, volatile: Bool? = nil) {
        self.role = role; self.subrole = subrole; self.title = title
        self.identifier = identifier; self.description = description; self.index = index; self.volatile = volatile
    }

    /// "power.circle.fill": lowercase words joined by dots, the way SF Symbol names look.
    public static func looksLikeSymbolName(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)+$"#, options: .regularExpression) != nil
    }

    /// Rank of a node for this matcher: 3 identifier, 2 exact title, 1 title contains / no text criteria,
    /// nil = does not match (role/subrole/description filter failed, or a given title never matches).
    public func rank(role r: String?, subrole s: String?, title t: String?, identifier i: String?,
                     description d: String?) -> Int? {
        if !role.isEmpty, r != role { return nil }
        if let subrole, s != subrole { return nil }
        if let description, !(d ?? "").localizedCaseInsensitiveContains(description) { return nil }
        if let identifier, !identifier.isEmpty, i == identifier { return 3 }
        if let title, !title.isEmpty {
            guard let t else { return nil }
            if t == title { return 2 }
            if t.localizedCaseInsensitiveContains(title) { return 1 }
            return nil
        }
        // Only an identifier was given and it did not match.
        if let identifier, !identifier.isEmpty { return nil }
        return 1
    }

    /// Highest rank this matcher can produce; the search may stop once it is reached.
    var topRank: Int {
        if let identifier, !identifier.isEmpty { return 3 }
        if let title, !title.isEmpty { return 2 }
        return 1
    }
}

/// What a step needs to see before it counts as done.
public struct ElementExpectation: Codable, Equatable, Sendable {
    /// The element's AXValue or AXTitle must contain this (case-insensitive).
    public var contains: String?
    public init(contains: String? = nil) { self.contains = contains }
}

public enum ActionStep: Codable, Equatable, Sendable {
    case launchApp(bundleID: String)
    /// `skipIfShowing`: when this element exists the press is skipped (for example "Connected" is already on screen).
    case press(locator: ElementLocator, timeout: TimeInterval = ActionDefaults.uiTimeout, skipIfShowing: ElementLocator? = nil)
    case menu(bundleID: String, path: [String])
    case typeText(text: String, into: ElementLocator? = nil)
    case key(combo: String)
    case shell(command: String, waitForExit: Bool = true, timeout: TimeInterval = ActionDefaults.shellTimeout)
    case openURL(url: String)
    case runShortcut(name: String)
    case waitFor(locator: ElementLocator, containing: String? = nil, timeout: TimeInterval = ActionDefaults.uiTimeout)
    case delay(seconds: TimeInterval)
    /// Wraps a step so that its failure does not stop the action.
    indirect case optional(step: ActionStep)

    /// How long the step may take before it fails.
    public var timeout: TimeInterval {
        switch self {
        case .press(_, let t, _), .shell(_, _, let t), .waitFor(_, _, let t): return t
        case .launchApp: return ActionDefaults.launchTimeout
        case .menu, .key, .typeText: return ActionDefaults.uiTimeout
        case .openURL, .runShortcut: return ActionDefaults.shellTimeout
        case .delay(let s): return s + 1
        case .optional(let inner): return inner.timeout
        }
    }

    /// Whether a failure of this step lets the action go on.
    public var continueOnFailure: Bool {
        if case .optional = self { return true }
        return false
    }

    /// The step without an `.optional` wrapper.
    public var unwrapped: ActionStep {
        if case .optional(let inner) = self { return inner.unwrapped }
        return self
    }

    public var summary: String {
        switch self {
        case .launchApp(let b): return "launch \(b)"
        case .press(let l, _, _): return "press \(l.describe)"
        case .menu(let b, let p): return "menu \(b): \(p.joined(separator: " > "))"
        case .typeText(let t, _): return "type \(t.count) characters"
        case .key(let k): return "key \(k)"
        case .shell(let c, _, _): return "shell \(c)"
        case .openURL(let u): return "open \(u)"
        case .runShortcut(let n): return "shortcut \(n)"
        case .waitFor(let l, _, _): return "wait for \(l.describe)"
        case .delay(let s): return "delay \(s)s"
        case .optional(let inner): return "optional " + inner.summary
        }
    }
}

/// Decoding for `ActionStep`. Encoding stays synthesized (`{"press":{"locator":...}}`). Steps saved before
/// P9.6 put their unlabeled values under "_0", so each labeled value is read from its label first, then "_0".
extension ActionStep {
    private struct StepKey: CodingKey {
        var stringValue: String
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: StepKey.self)
        guard outer.allKeys.count == 1, let kind = outer.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "A step must have exactly one kind key"))
        }
        let p = try outer.nestedContainer(keyedBy: StepKey.self, forKey: kind)
        func value<T: Decodable>(_ type: T.Type, _ label: String) throws -> T {
            if let v = try p.decodeIfPresent(T.self, forKey: StepKey(label)) { return v }
            return try p.decode(T.self, forKey: StepKey("_0"))
        }
        func optionalValue<T: Decodable>(_ type: T.Type, _ label: String) throws -> T? {
            try p.decodeIfPresent(T.self, forKey: StepKey(label))
        }
        func timeout(_ fallback: TimeInterval) throws -> TimeInterval {
            try p.decodeIfPresent(TimeInterval.self, forKey: StepKey("timeout")) ?? fallback
        }
        switch kind.stringValue {
        case "launchApp":
            self = .launchApp(bundleID: try p.decode(String.self, forKey: StepKey("bundleID")))
        case "press":
            self = .press(locator: try value(ElementLocator.self, "locator"), timeout: try timeout(ActionDefaults.uiTimeout),
                          skipIfShowing: try optionalValue(ElementLocator.self, "skipIfShowing"))
        case "menu":
            self = .menu(bundleID: try p.decode(String.self, forKey: StepKey("bundleID")),
                         path: try p.decode([String].self, forKey: StepKey("path")))
        case "typeText":
            self = .typeText(text: try value(String.self, "text"), into: try optionalValue(ElementLocator.self, "into"))
        case "key":
            self = .key(combo: try value(String.self, "combo"))
        case "shell":
            self = .shell(command: try p.decode(String.self, forKey: StepKey("command")),
                          waitForExit: try optionalValue(Bool.self, "waitForExit") ?? true,
                          timeout: try timeout(ActionDefaults.shellTimeout))
        case "openURL":
            self = .openURL(url: try value(String.self, "url"))
        case "runShortcut":
            self = .runShortcut(name: try p.decode(String.self, forKey: StepKey("name")))
        case "waitFor":
            self = .waitFor(locator: try value(ElementLocator.self, "locator"),
                            containing: try optionalValue(String.self, "containing"),
                            timeout: try timeout(ActionDefaults.uiTimeout))
        case "delay":
            self = .delay(seconds: try p.decode(TimeInterval.self, forKey: StepKey("seconds")))
        case "optional":
            self = .optional(step: try value(ActionStep.self, "step"))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown step kind \(kind.stringValue)"))
        }
    }
}

public enum ActionDefaults {
    public static let uiTimeout: TimeInterval = 5
    public static let launchTimeout: TimeInterval = 15
    public static let shellTimeout: TimeInterval = 60
    public static let pollInterval: TimeInterval = 0.2
    public static let maxDepth = 25
    public static let maxNodes = 5000
}

extension ElementLocator {
    var describe: String {
        let parts = path.map { m in m.title ?? m.identifier ?? m.description ?? m.role }
        return "\(bundleID) / " + parts.joined(separator: " > ")
    }
}

/// A key combination such as "cmd+shift+t".
public struct KeyCombo: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }
    public var modifiers: Modifiers
    public var keyCode: UInt16

    public static func parse(_ text: String) -> KeyCombo? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var mods: Modifiers = []
        for p in parts.dropLast() {
            switch p {
            case "cmd", "command", "meta": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: return nil
            }
        }
        guard let code = keyCodes[last] else { return nil }
        return KeyCombo(modifiers: mods, keyCode: code)
    }

    static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111,
    ]
}
