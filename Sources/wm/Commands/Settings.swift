import Foundation
import WMCore

/// The app's preferences domain; the CLI reads and writes the same keys the app uses.
private let appPreferencesDomain = "dev.windowsmanager.WindowsManager"

private func settingsStore() throws -> SettingsStore {
    try cliService { try SettingsStore(suiteName: appPreferencesDomain) }
}

func registerSettingsCommands(_ r: Registry) {
    r.register(Command(["settings", "list"], summary: "List all settings with values and defaults") { _, _ in
        let entries = try settingsStore().list()
        let data = JSONValue.object(["settings": .array(entries.map(CLISettingFormat.entry))])
        return CLIResult(data: data, text: entries.map(CLISettingFormat.line).joined(separator: "\n"))
    })

    r.register(Command(["settings", "get"], summary: "Show one setting", args: [CLIArg("key")]) { a, _ in
        let key = a.positionals[0]
        let value = try cliService { try settingsStore().get(key) }
        let data = JSONValue.object(["key": .string(key), "value": CLISettingFormat.json(value)])
        return CLIResult(data: data, text: value.description)
    })

    r.register(Command(["settings", "set"], summary: "Set one setting from text, e.g. wm settings set snap.gap 8",
                       args: [CLIArg("key"), CLIArg("value")]) { a, _ in
        let key = a.positionals[0]
        let text = a.positionals[1]
        let store = try settingsStore()
        try cliService { try store.set(key, text: text) }
        let value = try cliService { try store.get(key) }
        let data = JSONValue.object(["key": .string(key), "value": CLISettingFormat.json(value)])
        return CLIResult(data: data, text: "\(key) = \(value)")
    })

    r.register(Command(["settings", "reset"], summary: "Remove a stored value so the default applies", args: [CLIArg("key")]) { a, _ in
        let key = a.positionals[0]
        let store = try settingsStore()
        try cliService { try store.reset(key) }
        let value = try cliService { try store.get(key) }
        let data = JSONValue.object(["key": .string(key), "value": CLISettingFormat.json(value)])
        return CLIResult(data: data, text: "\(key) = \(value)")
    })
}
