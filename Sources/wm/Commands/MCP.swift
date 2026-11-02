import Foundation
import WMCore

/// `wm mcp`: Model Context Protocol server over stdio. Each tool call spawns this executable with `--json`.
func registerMCPCommands(_ r: Registry) {
    r.register(Command(["mcp"], summary: "Run a Model Context Protocol server over stdio (claude mcp add windows-manager -- wm mcp)") { _, _ in
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let path = FileManager.default.isExecutableFile(atPath: exe) ? exe : (Bundle.main.executablePath ?? exe)
        let server = MCPServer(commands: r.commands, version: wmVersion, agentGuide: agentGuideMarkdown) { args in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.standardError
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch {
                FileHandle.standardError.write(Data("wm mcp: cannot spawn \(path): \(error)\n".utf8))
                return ("", 1)
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (s, p.terminationStatus)
        }
        server.serve()
        exit(0)
    })
}
