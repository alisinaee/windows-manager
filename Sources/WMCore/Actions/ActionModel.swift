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

    public init(id: UUID = UUID(), name: String, phase: ActionPhase = .afterRestore,
                steps: [ActionStep] = [], enabled: Bool = true) {
        self.id = id; self.name = name; self.phase = phase; self.steps = steps; self.enabled = enabled
    }
}

/// One AX element to find, described level by level from the app's windows downward.
public struct ElementLocator: Codable, Equatable, Sendable {
    public var bundleID: String
    public var path: [ElementMatcher]
    public init(bundleID: String, path: [ElementMatcher]) { self.bundleID = bundleID; self.path = path }
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

    public init(role: String, subrole: String? = nil, title: String? = nil, identifier: String? = nil,
                description: String? = nil, index: Int? = nil) {
        self.role = role; self.subrole = subrole; self.title = title
        self.identifier = identifier; self.description = description; self.index = index
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
    case press(ElementLocator, timeout: TimeInterval = ActionDefaults.uiTimeout)
    case menu(bundleID: String, path: [String])
    case typeText(String, into: ElementLocator? = nil)
    case key(String)
    case shell(command: String, waitForExit: Bool = true, timeout: TimeInterval = ActionDefaults.shellTimeout)
    case openURL(String)
    case runShortcut(name: String)
    case waitFor(ElementLocator, containing: String? = nil, timeout: TimeInterval = ActionDefaults.uiTimeout)
    case delay(seconds: TimeInterval)
    /// Wraps a step so that its failure does not stop the action.
    indirect case optional(ActionStep)

    /// How long the step may take before it fails.
    public var timeout: TimeInterval {
        switch self {
        case .press(_, let t), .shell(_, _, let t), .waitFor(_, _, let t): return t
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
        case .press(let l, _): return "press \(l.describe)"
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
