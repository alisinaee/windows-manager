import Foundation

/// File logic behind Settings > AI Agents: links the `wm` tool into ~/.local/bin and writes the
/// Claude skill into ~/.claude/skills. The home folder is injectable so tests use a temp folder.
public struct AgentInstaller {
    public enum CLIStatus: Equatable {
        case installed
        case pointsElsewhere(String)
        case notInstalled
        case sourceMissing
    }

    public enum SkillStatus: Equatable {
        case installed
        case outdated
        case notInstalled
    }

    public let home: URL
    /// The `wm` binary to link to; nil when the app does not ship one.
    public let wmBinary: URL?
    public let runner: ProcessRunner
    public let isExecutable: @Sendable (String) -> Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, wmBinary: URL?,
                runner: @escaping ProcessRunner = AgentInstaller.systemRunner,
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.home = home
        self.wmBinary = wmBinary
        self.runner = runner
        self.isExecutable = isExecutable
    }

    public struct ProcessResult: Equatable, Sendable {
        public var status: Int32
        public var output: String
        public init(status: Int32, output: String) { self.status = status; self.output = output }
    }
    public typealias ProcessRunner = @Sendable (_ executable: String, _ args: [String]) -> ProcessResult

    public static let systemRunner: ProcessRunner = { exe, args in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ProcessResult(status: 127, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ProcessResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    public enum DesktopStatus: Equatable {
        case claudeNotInstalled
        case notConnected
        case connected
        case connectedOtherPath(String)
    }

    public enum CodeStatus: Equatable {
        case cliMissing
        case notConnected
        case connected
    }

    public static let serverName = "windows-manager"

    /// Path written into the Claude configs: the installed link if present, else the bundled wm.
    public var mcpWMPath: String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: linkURL.path) { return linkURL.path }
        return wmBinary?.path
    }

    // MARK: Claude Desktop

    public var desktopDir: URL { home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true) }
    public var desktopConfigURL: URL { desktopDir.appendingPathComponent("claude_desktop_config.json") }

    private func readDesktopConfig() throws -> [String: Any] {
        guard fm.fileExists(atPath: desktopConfigURL.path) else { return [:] }
        let data = try Data(contentsOf: desktopConfigURL)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentInstallError.invalidConfig(desktopConfigURL.path)
        }
        return obj
    }

    private func backupDesktopConfig() throws {
        guard fm.fileExists(atPath: desktopConfigURL.path) else { return }
        var dest = desktopDir.appendingPathComponent("claude_desktop_config.json.bak-wm")
        if fm.fileExists(atPath: dest.path) {
            dest = desktopDir.appendingPathComponent("claude_desktop_config.json.bak-wm-\(Int(Date().timeIntervalSince1970))")
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        }
        try fm.copyItem(at: desktopConfigURL, to: dest)
    }

    private func writeDesktopConfig(_ obj: [String: Any]) throws {
        try fm.createDirectory(at: desktopDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: desktopConfigURL, options: .atomic)
    }

    public func desktopStatus() -> DesktopStatus {
        guard fm.fileExists(atPath: desktopDir.path) else { return .claudeNotInstalled }
        guard let cfg = try? readDesktopConfig(),
              let servers = cfg["mcpServers"] as? [String: Any],
              let entry = servers[Self.serverName] as? [String: Any] else { return .notConnected }
        let cmd = entry["command"] as? String ?? ""
        if let want = mcpWMPath, cmd != want { return .connectedOtherPath(cmd) }
        return .connected
    }

    public func connectDesktop() throws {
        guard let wm = mcpWMPath else { throw AgentInstallError.binaryMissing }
        var cfg = try readDesktopConfig()
        try backupDesktopConfig()
        var servers = cfg["mcpServers"] as? [String: Any] ?? [:]
        servers[Self.serverName] = ["command": wm, "args": ["mcp"]] as [String: Any]
        cfg["mcpServers"] = servers
        try writeDesktopConfig(cfg)
    }

    public func disconnectDesktop() throws {
        var cfg = try readDesktopConfig()
        guard var servers = cfg["mcpServers"] as? [String: Any], servers[Self.serverName] != nil else { return }
        try backupDesktopConfig()
        servers.removeValue(forKey: Self.serverName)
        cfg["mcpServers"] = servers
        try writeDesktopConfig(cfg)
    }

    // MARK: Claude Code

    /// The `claude` CLI path: login-shell PATH first, then the usual install spots.
    public func findClaude() -> String? {
        let r = runner("/bin/zsh", ["-lc", "command -v claude"])
        if r.status == 0 {
            let line = r.output.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if line.hasPrefix("/"), isExecutable(line) { return line }
        }
        let candidates = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { isExecutable($0) }
    }

    public func codeStatus() -> CodeStatus {
        guard let claude = findClaude() else { return .cliMissing }
        let r = runner(claude, ["mcp", "get", Self.serverName])
        return r.status == 0 && r.output.contains(Self.serverName) ? .connected : .notConnected
    }

    public func connectCode() throws {
        guard let wm = mcpWMPath else { throw AgentInstallError.binaryMissing }
        guard let claude = findClaude() else { throw AgentInstallError.claudeCLIMissing }
        if codeStatus() == .connected {
            _ = runner(claude, ["mcp", "remove", "--scope", "user", Self.serverName])
        }
        let r = runner(claude, ["mcp", "add", "--scope", "user", Self.serverName, "--", wm, "mcp"])
        if r.status != 0 { throw AgentInstallError.commandFailed(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public func disconnectCode() throws {
        guard let claude = findClaude() else { throw AgentInstallError.claudeCLIMissing }
        let r = runner(claude, ["mcp", "remove", "--scope", "user", Self.serverName])
        if r.status != 0 { throw AgentInstallError.commandFailed(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public var binDir: URL { home.appendingPathComponent(".local/bin", isDirectory: true) }
    public var linkURL: URL { binDir.appendingPathComponent("wm") }
    public var skillURL: URL { home.appendingPathComponent(".claude/skills/wm-agent/SKILL.md") }

    private var fm: FileManager { .default }

    public func cliStatus() -> CLIStatus {
        guard let target = try? fm.destinationOfSymbolicLink(atPath: linkURL.path) else {
            if fm.fileExists(atPath: linkURL.path) { return .pointsElsewhere(linkURL.path) }
            return wmBinary == nil ? .sourceMissing : .notInstalled
        }
        guard let wmBinary else { return .pointsElsewhere(target) }
        let same = URL(fileURLWithPath: target).standardizedFileURL.path == wmBinary.standardizedFileURL.path
        return same ? .installed : .pointsElsewhere(target)
    }

    public func installCLI() throws {
        guard let wmBinary else { throw AgentInstallError.binaryMissing }
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: linkURL.path)) != nil || fm.fileExists(atPath: linkURL.path) {
            try fm.removeItem(at: linkURL)
        }
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: wmBinary)
    }

    /// Removes the link only when it is a symlink; a regular file the user put there is left alone.
    public func uninstallCLI() throws {
        guard (try? fm.destinationOfSymbolicLink(atPath: linkURL.path)) != nil else { return }
        try fm.removeItem(at: linkURL)
    }

    public func isBinDirOnPath(_ path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> Bool {
        let dir = binDir.standardizedFileURL.path
        return path.split(separator: ":").contains { URL(fileURLWithPath: String($0)).standardizedFileURL.path == dir }
    }

    public var pathHint: String { "export PATH=\"$HOME/.local/bin:$PATH\"" }

    public func skillStatus(expected: String) -> SkillStatus {
        guard let text = try? String(contentsOf: skillURL, encoding: .utf8) else { return .notInstalled }
        return text == expected ? .installed : .outdated
    }

    public func installSkill(_ text: String) throws {
        try fm.createDirectory(at: skillURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: skillURL, atomically: true, encoding: .utf8)
    }

    public func uninstallSkill() throws {
        let dir = skillURL.deletingLastPathComponent()
        guard fm.fileExists(atPath: skillURL.path) else { return }
        try fm.removeItem(at: skillURL)
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try fm.removeItem(at: dir) }
    }

    public static let mcpCommand = "claude mcp add windows-manager -- wm mcp"

    /// Claude Desktop config snippet; the app never writes that file itself.
    public func desktopConfigJSON(wmPath: String) -> String {
        let obj: [String: Any] = ["mcpServers": ["windows-manager": ["command": wmPath, "args": ["mcp"]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}

public enum AgentInstallError: LocalizedError {
    case binaryMissing
    case invalidConfig(String)
    case claudeCLIMissing
    case commandFailed(String)
    public var errorDescription: String? {
        switch self {
        case .binaryMissing: return "The wm tool is not included in this build of the app."
        case .invalidConfig(let p): return "Could not read \(p) as JSON. Nothing was changed."
        case .claudeCLIMissing: return "The claude command line tool was not found."
        case .commandFailed(let m): return m.isEmpty ? "The claude command failed." : m
        }
    }
}
