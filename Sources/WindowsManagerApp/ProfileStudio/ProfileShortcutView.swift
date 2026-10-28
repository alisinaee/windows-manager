import AppKit
import KeyboardShortcuts
import SwiftUI
import WMCore

/// Run shortcut of one saved profile, set from the Studio. It records into the same KeyboardShortcuts name
/// (`.profile(id)`) as Settings > Hotkeys, so both places always show the same value.
struct ProfileShortcutView: View {
    let profileID: UUID
    let profileName: String

    @State private var current: KeyboardShortcuts.Shortcut?
    @State private var showSuggestions = false
    /// Changed to rebuild the recorder after a suggestion or clear, which it does not notice by itself.
    @State private var recorderRevision = 0

    private var name: KeyboardShortcuts.Name { .profile(profileID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Run shortcut").font(.caption.bold()).foregroundStyle(.secondary).textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                KeyboardShortcuts.Recorder(for: name) { shortcut in
                    current = shortcut
                    DebugLog.log("studio", shortcut.map { "shortcut set for \(profileName): \($0)" } ?? "shortcut cleared for \(profileName)")
                }
                .id(recorderRevision)
                .font(.callout)
                .help("Click here, then press the shortcut to use for this profile. The same shortcut appears in Settings > Hotkeys.")
                Button { showSuggestions = true } label: { Image(systemName: "lightbulb") }
                    .help("Suggested shortcuts")
                    .accessibilityLabel("Suggested shortcuts")
                    .popover(isPresented: $showSuggestions, arrowEdge: .bottom) { suggestions }
            }
            if let current, let advice = ShortcutAdvice.warning(for: Self.combo(current)) {
                Label("\(advice) It may clash with macOS.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if current == nil {
                Text("No shortcut yet. Click the field and press a combination, or pick a suggestion (lightbulb). Shortcuts also appear in Settings > Hotkeys.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { current = KeyboardShortcuts.getShortcut(for: name) }
        .onChange(of: profileID) { _ in
            current = KeyboardShortcuts.getShortcut(for: name)
            recorderRevision += 1
        }
    }

    // MARK: Suggestions

    private var suggestions: some View {
        let taken = takenCombos()
        let own = current.map(Self.combo)
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Control + Option + Command + number is the safest choice: macOS and apps almost never use it. Control + Option + number is lighter but a few apps bind it. Shortcuts already used here are greyed out.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                suggestionGroup("Safest", ShortcutAdvice.hyperSuggestions, taken: taken, own: own)
                suggestionGroup("Lighter", ShortcutAdvice.lightSuggestions, taken: taken, own: own)
                if current != nil {
                    Button("Clear shortcut", role: .destructive) { assign(nil) }
                        .help("Remove this profile's run shortcut")
                }
            }
            .padding(12)
        }
        .frame(width: 300)
        .frame(maxHeight: 420)
    }

    private func suggestionGroup(_ title: String, _ combos: [ShortcutCombo], taken: [ShortcutCombo: String], own: ShortcutCombo?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(combos, id: \.self) { combo in
                    let reason = ShortcutAdvice.conflict(for: combo, taken: taken, ownCombo: own)
                    Button { assign(combo) } label: { Text(Self.text(combo)).frame(maxWidth: .infinity) }
                        .disabled(reason != nil)
                        .help(reason ?? (combo == own ? "Current shortcut" : "Use this shortcut"))
                }
            }
            let used = combos.compactMap { c in ShortcutAdvice.conflict(for: c, taken: taken, ownCombo: own).map { (c, $0) } }
            ForEach(used, id: \.0) { combo, why in
                Text("\(Self.text(combo)): \(why)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func assign(_ combo: ShortcutCombo?) {
        let shortcut = combo.map {
            KeyboardShortcuts.Shortcut(KeyboardShortcuts.Key(rawValue: $0.keyCode), modifiers: Self.flags($0.modifiers))
        }
        KeyboardShortcuts.setShortcut(shortcut, for: name)
        current = shortcut
        recorderRevision += 1
        HotkeyController.shared.syncProfiles()
        DebugLog.log("studio", combo.map { "shortcut suggested for \(profileName): \(Self.text($0))" } ?? "shortcut cleared for \(profileName)")
        showSuggestions = false
    }

    /// Every shortcut other hotkeys of this app use, with the owner's name.
    private func takenCombos() -> [ShortcutCombo: String] {
        var taken: [ShortcutCombo: String] = [:]
        func add(_ name: KeyboardShortcuts.Name, _ owner: String) {
            if let shortcut = KeyboardShortcuts.getShortcut(for: name) { taken[Self.combo(shortcut)] = owner }
        }
        add(.nextWorkspace, "Next workspace")
        add(.previousWorkspace, "Previous workspace")
        for (i, n) in KeyboardShortcuts.Name.workspaceIndexed.enumerated() { add(n, "Workspace \(i + 1)") }
        for (i, n) in KeyboardShortcuts.Name.snapZones.enumerated() { add(n, "Snap zone \(i + 1)") }
        for profile in AppState.current?.savedProfiles ?? [] where profile.id != profileID {
            add(.profile(profile.id), "profile \(profile.name)")
        }
        return taken
    }

    // MARK: Conversion

    static func combo(_ shortcut: KeyboardShortcuts.Shortcut) -> ShortcutCombo {
        let flags = shortcut.modifiers
        var mods: ShortcutModifiers = []
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        return ShortcutCombo(keyCode: shortcut.carbonKeyCode, modifiers: mods)
    }

    private static func flags(_ mods: ShortcutModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.contains(.control) { flags.insert(.control) }
        if mods.contains(.option) { flags.insert(.option) }
        if mods.contains(.shift) { flags.insert(.shift) }
        if mods.contains(.command) { flags.insert(.command) }
        return flags
    }

    private static func text(_ combo: ShortcutCombo) -> String {
        var s = ""
        if combo.modifiers.contains(.control) { s += "\u{2303}" }
        if combo.modifiers.contains(.option) { s += "\u{2325}" }
        if combo.modifiers.contains(.shift) { s += "\u{21E7}" }
        if combo.modifiers.contains(.command) { s += "\u{2318}" }
        return s + (ShortcutAdvice.digit(forKeyCode: combo.keyCode).map(String.init) ?? "?")
    }
}
