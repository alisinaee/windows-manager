import Foundation
import WMCore

let wmVersion = "0.1.0"

func registerCoreCommands(_ r: Registry) {
    r.register(Command(["version"], summary: "Print the wm version") { _, _ in
        CLIResult(data: .object(["version": .string(wmVersion)]), text: "wm \(wmVersion)")
    })
    r.register(Command(["commands"], summary: "List all registered commands (machine readable with --json)") { _, _ in
        let list = r.commands.sorted { $0.name < $1.name }
        return CLIResult(data: .object(["commands": .array(list.map { $0.descriptor })]),
                         text: list.map { "\($0.name)\t\($0.summary)" }.joined(separator: "\n"))
    })
}
