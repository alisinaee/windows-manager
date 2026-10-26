import Foundation
import WMCore

/// `spaceslab ctl run <name> | list | capture <name>`: asks the running Windows Manager app to act,
/// by opening a windowsmanager:// URL.
enum CtlCommand {
    static let name = "ctl"
    static let help = "Control the app: ctl run <name> | list | capture <name>"

    static func run(_ args: [String]) -> Int32 {
        let command: ControlCommand
        do {
            command = try ControlCommand.parse(arguments: args)
        } catch {
            fputs("\(error)\n", stderr)
            return 2
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [command.url.absoluteString]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fputs("Could not run /usr/bin/open: \(error.localizedDescription)\n", stderr)
            return 1
        }
        return process.terminationStatus == 0 ? 0 : 1
    }
}
