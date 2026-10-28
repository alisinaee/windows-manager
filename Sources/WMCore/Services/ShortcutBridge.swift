import Foundation

/// Converts a profile run shortcut between its text form ("ctrl+opt+cmd+1", stored in `options.hotkey`)
/// and the (carbonKeyCode, carbonModifiers) pair KeyboardShortcuts keeps in UserDefaults.
/// Only digits 1-9 with any of ctrl/opt/shift/cmd are representable; everything else returns nil and
/// callers leave the shortcut as it is. Pure, so the app and the CLI agree without importing AppKit.
public enum ShortcutBridge {
    // Carbon modifier bits (Events.h): cmdKey, shiftKey, optionKey, controlKey.
    public static let carbonCommand = 1 << 8
    public static let carbonShift = 1 << 9
    public static let carbonOption = 1 << 11
    public static let carbonControl = 1 << 12
    private static let carbonKnownBits = carbonCommand | carbonShift | carbonOption | carbonControl

    /// Carbon modifier bits for the modifiers of a combo.
    public static func carbonModifiers(_ modifiers: ShortcutModifiers) -> Int {
        var bits = 0
        if modifiers.contains(.control) { bits |= carbonControl }
        if modifiers.contains(.option) { bits |= carbonOption }
        if modifiers.contains(.shift) { bits |= carbonShift }
        if modifiers.contains(.command) { bits |= carbonCommand }
        return bits
    }

    /// The modifiers of Carbon bits, or nil when the bits hold anything else (fn, caps lock, and so on).
    public static func modifiers(carbon bits: Int) -> ShortcutModifiers? {
        guard bits & ~carbonKnownBits == 0 else { return nil }
        var mods: ShortcutModifiers = []
        if bits & carbonControl != 0 { mods.insert(.control) }
        if bits & carbonOption != 0 { mods.insert(.option) }
        if bits & carbonShift != 0 { mods.insert(.shift) }
        if bits & carbonCommand != 0 { mods.insert(.command) }
        return mods
    }

    /// The combo for a stored (carbonKeyCode, carbonModifiers) pair, or nil when it is not representable
    /// (another key, no modifier, or modifier bits outside ctrl/opt/shift/cmd).
    public static func combo(carbonKeyCode: Int, carbonModifiers bits: Int) -> ShortcutCombo? {
        guard ShortcutAdvice.digit(forKeyCode: carbonKeyCode) != nil,
              let mods = modifiers(carbon: bits), !mods.isEmpty else { return nil }
        return ShortcutCombo(keyCode: carbonKeyCode, modifiers: mods)
    }

    /// The (carbonKeyCode, carbonModifiers) pair of a combo.
    public static func carbon(of combo: ShortcutCombo) -> (carbonKeyCode: Int, carbonModifiers: Int) {
        (combo.keyCode, carbonModifiers(combo.modifiers))
    }

    /// Text form of a stored pair, such as "ctrl+opt+cmd+1", or nil when it is not representable.
    public static func text(carbonKeyCode: Int, carbonModifiers bits: Int) -> String? {
        combo(carbonKeyCode: carbonKeyCode, carbonModifiers: bits).map(ProfileService.formatShortcut)
    }

    /// The stored pair for a text shortcut, or nil when the text is not a valid shortcut.
    public static func carbon(text: String) -> (carbonKeyCode: Int, carbonModifiers: Int)? {
        guard let combo = try? ProfileService.parseShortcut(text) else { return nil }
        return carbon(of: combo)
    }
}
