import Foundation
import WMCore

func registerSchemaCommands(_ r: Registry) {
    r.register(Command(["schema"], summary: "Machine-readable list of every command, its flags, safety metadata, exit codes and envelope") { _, _ in
        CLIResult(data: CLISchema.document(version: wmVersion, commands: r.commands))
    })
}
