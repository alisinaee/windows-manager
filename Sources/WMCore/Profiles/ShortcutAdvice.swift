import Foundation

/// Modifier keys of a shortcut, independent of AppKit/Carbon so the advice below stays pure and testable.
public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = ShortcutModifiers(rawValue: 1)
    public static let option = ShortcutModifiers(rawValue: 2)
    public static let shift = ShortcutModifiers(rawValue: 4)
    public static let command = ShortcutModifiers(rawValue: 8)
}

/// A shortcut as a macOS virtual key code (the ANSI layout numbers Carbon uses) plus modifiers.
public struct ShortcutCombo: Hashable, Sendable {
    public var keyCode: Int
    public var modifiers: ShortcutModifiers
    public init(keyCode: Int, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Advice about profile run shortcuts: which combos to suggest and which well-known system ones to warn about.
public enum ShortcutAdvice {
    /// Virtual key codes of the digits 1...9 on the main keyboard row (they are not in numeric order).
    public static let digitKeyCodes: [Int] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// The safest set: Control+Option+Command+1...9. Almost no app or macOS feature uses it.
    public static let hyperSuggestions: [ShortcutCombo] = digitKeyCodes.map {
        ShortcutCombo(keyCode: $0, modifiers: [.control, .option, .command])
    }

    /// The lighter set: Control+Option+1...9. Rarely used, but a few apps do bind it.
    public static let lightSuggestions: [ShortcutCombo] = digitKeyCodes.map {
        ShortcutCombo(keyCode: $0, modifiers: [.control, .option])
    }

    /// The digit (1...9) a key code stands for, or nil.
    public static func digit(forKeyCode code: Int) -> Int? {
        digitKeyCodes.firstIndex(of: code).map { $0 + 1 }
    }

    private static let system: [(ShortcutCombo, String)] = {
        let cmd: ShortcutModifiers = [.command]
        var list: [(ShortcutCombo, String)] = [
            (ShortcutCombo(keyCode: 49, modifiers: cmd), "Command+Space opens Spotlight."),
            (ShortcutCombo(keyCode: 48, modifiers: cmd), "Command+Tab switches apps."),
            (ShortcutCombo(keyCode: 12, modifiers: cmd), "Command+Q quits the frontmost app."),
            (ShortcutCombo(keyCode: 13, modifiers: cmd), "Command+W closes a window."),
            (ShortcutCombo(keyCode: 4, modifiers: cmd), "Command+H hides the frontmost app."),
            (ShortcutCombo(keyCode: 46, modifiers: cmd), "Command+M minimizes a window."),
            (ShortcutCombo(keyCode: 53, modifiers: [.command, .option]), "Command+Option+Esc opens Force Quit."),
        ]
        for code in [20, 21, 23] {
            list.append((ShortcutCombo(keyCode: code, modifiers: [.command, .shift]), "Command+Shift+3, 4 and 5 take screenshots."))
        }
        // Control+Arrow switches Spaces and opens Mission Control (left, right, up, down).
        for code in [123, 124, 125, 126] {
            list.append((ShortcutCombo(keyCode: code, modifiers: [.control]), "Control+Arrow is used by Mission Control."))
        }
        return list
    }()

    /// A short warning when the combo is a well-known system shortcut, otherwise nil.
    public static func warning(for combo: ShortcutCombo) -> String? {
        system.first { $0.0 == combo }?.1
    }

    /// The reason a suggested combo cannot be offered because another hotkey of this app already uses it, or nil.
    /// `taken` maps a combo to the name of what owns it; `ownCombo` is this profile's current one (never a clash).
    public static func conflict(for combo: ShortcutCombo, taken: [ShortcutCombo: String], ownCombo: ShortcutCombo?) -> String? {
        if combo == ownCombo { return nil }
        return taken[combo].map { "Already used by \($0)" }
    }

    /// The first suggestion nobody else uses: the safest set first, then the lighter one. Nil when all 18 are taken.
    public static func firstFreeSuggestion(taken: [ShortcutCombo: String], ownCombo: ShortcutCombo?) -> ShortcutCombo? {
        (hyperSuggestions + lightSuggestions).first { taken[$0] == nil || $0 == ownCombo }
    }
}
