import Foundation
import WMCore

let registry = Registry()
registerCoreCommands(registry)
registerAllCommands(registry)

let result = registry.execute(Array(CommandLine.arguments.dropFirst()))
if result.exit == .ok || !(CommandLine.arguments.contains("--json")) && result.exit == .partial {
    print(result.output)
} else if CommandLine.arguments.contains("--json") {
    print(result.output)   // envelopes always go to stdout
} else {
    FileHandle.standardError.write(Data((result.output + "\n").utf8))
}
exit(result.exit.rawValue)
