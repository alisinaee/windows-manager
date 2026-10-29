import Foundation

// `wm hotkeys list|set|clear`: the global hotkeys of the Hotkeys tab (workspace, snap zone, window size, move to
// display), read and written in the same UserDefaults keys KeyboardShortcuts uses
// (`KeyboardShortcuts_<name>` = JSON `{"carbonKeyCode":N,"carbonModifiers":M}`). The running app reads them at
// launch, so a change applies after the app restarts. Per-profile shortcuts stay `wm profile shortcut`.

/// Key names for any key a global hotkey can use, as macOS virtual key codes (ANSI layout).
public enum HotkeyKeys {
    private static let table: [(String, Int)] = {
        var t: [(String, Int)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17),
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("equal", 24), ("9", 25), ("7", 26),
            ("minus", 27), ("8", 28), ("0", 29), ("rightbracket", 30), ("o", 31), ("u", 32), ("leftbracket", 33),
            ("i", 34), ("p", 35), ("return", 36), ("l", 37), ("j", 38), ("quote", 39), ("k", 40), ("semicolon", 41),
            ("backslash", 42), ("comma", 43), ("slash", 44), ("n", 45), ("m", 46), ("period", 47), ("tab", 48),
            ("space", 49), ("grave", 50), ("delete", 51), ("esc", 53),
            ("left", 123), ("right", 124), ("down", 125), ("up", 126),
        ]
        let f: [Int] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in f.enumerated() { t.append(("f\(i + 1)", code)) }
        return t
    }()
    private static let aliases = ["escape": "esc", "enter": "return", "backspace": "delete", "plus": "equal"]

    public static func keyCode(named raw: String) -> Int? {
        let n = raw.lowercased()
        let name = aliases[n] ?? n
        return table.first { $0.0 == name }?.1
    }

    public static func name(forKeyCode code: Int) -> String? { table.first { $0.1 == code }?.0 }

    /// Parses "ctrl+opt+cmd+left". Separators are "+" or spaces (so "minus" names the - key).
    public static func parse(_ text: String) throws -> ShortcutCombo {
        let bad = ServiceError.invalid("Shortcut \"\(text)\" is not valid. Use modifiers (ctrl, opt, shift, cmd) and one key, for example ctrl+opt+cmd+left or ctrl+opt+1.")
        var mods: ShortcutModifiers = []
        var key: Int?
        for raw in text.lowercased().split(whereSeparator: { "+ ".contains($0) }) {
            switch raw {
            case "ctrl", "control": mods.insert(.control)
            case "opt", "option", "alt": mods.insert(.option)
            case "shift": mods.insert(.shift)
            case "cmd", "command": mods.insert(.command)
            default:
                guard key == nil, let code = keyCode(named: String(raw)) else { throw bad }
                key = code
            }
        }
        guard let key, !mods.isEmpty else { throw bad }
        return ShortcutCombo(keyCode: key, modifiers: mods)
    }

    /// Text form such as "ctrl+opt+cmd+left"; nil when the key or modifier bits are not representable.
    public static func text(carbonKeyCode: Int, carbonModifiers bits: Int) -> String? {
        guard let key = name(forKeyCode: carbonKeyCode), let mods = ShortcutBridge.modifiers(carbon: bits) else { return nil }
        var parts: [String] = []
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.option) { parts.append("opt") }
        if mods.contains(.shift) { parts.append("shift") }
        if mods.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }
}

public struct HotkeyBinding: Codable, Equatable, Sendable {
    public var name: String
    public var title: String
    /// Text form, or nil when no shortcut is set (or the stored one is not representable).
    public var shortcut: String?
    public var carbonKeyCode: Int?
    public var carbonModifiers: Int?
}

public final class HotkeyStore {
    public static let keyPrefix = "KeyboardShortcuts_"

    /// The fixed hotkey names of the Hotkeys tab, with titles.
    public static let catalog: [(name: String, title: String)] = {
        var c: [(String, String)] = [("workspace.next", "Next workspace"), ("workspace.previous", "Previous workspace")]
        for i in 1...9 { c.append(("workspace.\(i)", "Switch to workspace \(i)")) }
        for i in 1...9 { c.append(("snap.zone.\(i)", "Snap to zone \(i)")) }
        for d in WindowSizeDirection.allCases { c.append(("window.size.\(d.rawValue)", "Window size: \(d.rawValue)")) }
        c.append(("display.move.next", "Move to next display"))
        c.append(("display.move.previous", "Move to previous display"))
        return c
    }()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public convenience init(suiteName: String) throws {
        guard let suite = UserDefaults(suiteName: suiteName) else { throw ServiceError.invalid("Cannot open settings domain \(suiteName).") }
        self.init(defaults: suite)
    }

    private func stored(_ name: String) -> (code: Int, bits: Int)? {
        let raw = defaults.object(forKey: Self.keyPrefix + name)
        let data: Data?
        if let s = raw as? String { data = s.data(using: .utf8) } else { data = raw as? Data }
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["carbonKeyCode"] as? Int, let bits = obj["carbonModifiers"] as? Int else { return nil }
        return (code, bits)
    }

    private func binding(_ name: String, _ title: String) -> HotkeyBinding {
        guard let s = stored(name) else { return HotkeyBinding(name: name, title: title) }
        return HotkeyBinding(name: name, title: title, shortcut: HotkeyKeys.text(carbonKeyCode: s.code, carbonModifiers: s.bits),
                             carbonKeyCode: s.code, carbonModifiers: s.bits)
    }

    /// Every fixed hotkey in catalog order, then the profile hotkeys found in the store (read only here).
    public func list() -> [HotkeyBinding] {
        var out = Self.catalog.map { binding($0.name, $0.title) }
        let profileKeys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.keyPrefix + "profile.") }.sorted()
        for key in profileKeys {
            let name = String(key.dropFirst(Self.keyPrefix.count))
            let b = binding(name, "Profile \(name.dropFirst("profile.".count))")
            if b.carbonKeyCode != nil { out.append(b) }
        }
        return out
    }

    private func requireKnown(_ name: String) throws {
        guard Self.catalog.contains(where: { $0.name == name }) else {
            throw ServiceError.notFound("No global hotkey \"\(name)\". Run: wm hotkeys list (profile shortcuts: wm profile shortcut).")
        }
    }

    @discardableResult
    public func set(_ name: String, shortcut: String) throws -> HotkeyBinding {
        try requireKnown(name)
        let combo = try HotkeyKeys.parse(shortcut)
        if let warning = ShortcutAdvice.warning(for: combo) { throw ServiceError.conflict(warning) }
        let pair = ShortcutBridge.carbon(of: combo)
        for other in list() where other.name != name {
            if other.carbonKeyCode == pair.carbonKeyCode, other.carbonModifiers == pair.carbonModifiers {
                throw ServiceError.conflict("Already used by \(other.title).")
            }
        }
        defaults.set("{\"carbonKeyCode\":\(pair.carbonKeyCode),\"carbonModifiers\":\(pair.carbonModifiers)}",
                     forKey: Self.keyPrefix + name)
        return binding(name, Self.catalog.first { $0.name == name }!.title)
    }

    @discardableResult
    public func clear(_ name: String) throws -> HotkeyBinding {
        try requireKnown(name)
        defaults.removeObject(forKey: Self.keyPrefix + name)
        return binding(name, Self.catalog.first { $0.name == name }!.title)
    }
}

public enum HotkeyCommands {
    static func line(_ b: HotkeyBinding) -> String { "\(b.name)\t\(b.shortcut ?? "-")\t\(b.title)" }

    public static func register(_ r: Registry, store: @escaping () throws -> HotkeyStore) {
        r.register(Command(["hotkeys", "list"], summary: "List the global hotkeys and their shortcuts") { _, _ in
            let all = try cliService { try store() }.list()
            return CLIResult(data: .object(["hotkeys": try JSONValue.from(all)]), text: all.map(line).joined(separator: "\n"))
        })
        r.register(Command(["hotkeys", "set"], summary: "Set a global hotkey, e.g. wm hotkeys set workspace.next ctrl+opt+cmd+right (applies after the app restarts)",
                           args: [CLIArg("name"), CLIArg("combo", "Modifiers (ctrl, opt, shift, cmd) plus one key")], mutates: true) { a, _ in
            let b = try cliService { try store().set(a.positionals[0], shortcut: a.positionals[1]) }
            return CLIResult(data: try JSONValue.from(b), text: line(b))
        })
        r.register(Command(["hotkeys", "clear"], summary: "Remove the shortcut of a global hotkey", args: [CLIArg("name")], mutates: true) { a, _ in
            let b = try cliService { try store().clear(a.positionals[0]) }
            return CLIResult(data: try JSONValue.from(b), text: "cleared \(b.name)")
        })
    }
}
