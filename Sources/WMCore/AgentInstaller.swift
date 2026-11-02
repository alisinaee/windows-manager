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

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, wmBinary: URL?) {
        self.home = home
        self.wmBinary = wmBinary
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
    public var errorDescription: String? {
        "The wm tool is not included in this build of the app."
    }
}
