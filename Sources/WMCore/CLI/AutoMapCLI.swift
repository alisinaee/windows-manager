import Foundation

// `wm rules auto-map list|set|remove`: which profile the auto profile feature runs for a monitor set.
// Without --key the monitor set of the displays connected now is used.

public enum AutoMapCommands {
    public static func register(_ r: Registry, rules: @escaping () -> RuleService, profiles: @escaping () -> ProfileService,
                                currentKey: @escaping () -> String) {
        r.register(Command(["rules", "auto-map", "list"], summary: "List monitor set to profile mappings and the current monitor set key") { _, _ in
            let map = rules().autoProfile().mapping
            let rows = map.sorted { $0.key < $1.key }
            let data = JSONValue.object([
                "currentKey": .string(currentKey()),
                "mapping": .object(Dictionary(uniqueKeysWithValues: rows.map { ($0.key, JSONValue.string($0.value.uuidString)) })),
            ])
            return CLIResult(data: data, text: (["current\t\(currentKey())"] + rows.map { "\($0.key)\t\($0.value.uuidString)" }).joined(separator: "\n"))
        })
        r.register(Command(["rules", "auto-map", "set"], summary: "Run a profile automatically for a monitor set", args: [CLIArg("profile")],
                           options: [CLIOption("key", "Monitor set key (default: the displays connected now)", takesValue: true, valueName: "key")],
                           mutates: true) { a, _ in
            let id = try cliService { try profiles().resolve(a.positionals[0]) }
            let key = a.value("key") ?? currentKey()
            let s = try cliService { try rules().setAutoProfileMapping(monitorSetKey: key, profileID: id) }
            return CLIResult(data: try JSONValue.from(s), text: "\(key) -> \(id.uuidString)")
        })
        r.register(Command(["rules", "auto-map", "remove"], summary: "Remove a mapping", options: [
            CLIOption("key", "Monitor set key (default: the displays connected now)", takesValue: true, valueName: "key")], mutates: true) { a, _ in
            let key = a.value("key") ?? currentKey()
            _ = try cliService { try rules().removeAutoProfileMapping(monitorSetKey: key) }
            return CLIResult(data: .object(["removed": .string(key)]), text: "removed \(key)")
        })
    }
}
