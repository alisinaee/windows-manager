import Foundation
import Testing
@testable import WMCore

@Suite struct AgentInstallerTests {
    private func makeHome() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func cliInstallStatusAndUninstall() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let wm = home.appendingPathComponent("wm-bin")
        try "x".write(to: wm, atomically: true, encoding: .utf8)
        let inst = AgentInstaller(home: home, wmBinary: wm)
        #expect(inst.cliStatus() == .notInstalled)
        try inst.installCLI()
        #expect(inst.cliStatus() == .installed)
        try inst.installCLI() // idempotent
        let other = AgentInstaller(home: home, wmBinary: home.appendingPathComponent("other"))
        #expect(other.cliStatus() == .pointsElsewhere(wm.path))
        try inst.uninstallCLI()
        #expect(inst.cliStatus() == .notInstalled)
    }

    @Test func missingBinary() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let inst = AgentInstaller(home: home, wmBinary: nil)
        #expect(inst.cliStatus() == .sourceMissing)
        #expect(throws: AgentInstallError.self) { try inst.installCLI() }
    }

    @Test func regularFileIsNotRemoved() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let inst = AgentInstaller(home: home, wmBinary: nil)
        try FileManager.default.createDirectory(at: inst.binDir, withIntermediateDirectories: true)
        try "real".write(to: inst.linkURL, atomically: true, encoding: .utf8)
        try inst.uninstallCLI()
        #expect(FileManager.default.fileExists(atPath: inst.linkURL.path))
    }

    @Test func skillRoundTrip() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let inst = AgentInstaller(home: home, wmBinary: nil)
        #expect(inst.skillStatus(expected: "a") == .notInstalled)
        try inst.installSkill("a")
        #expect(inst.skillStatus(expected: "a") == .installed)
        #expect(inst.skillStatus(expected: "b") == .outdated)
        try inst.uninstallSkill()
        #expect(inst.skillStatus(expected: "a") == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: inst.skillURL.deletingLastPathComponent().path))
    }

    @Test func pathAndJSON() throws {
        let home = URL(fileURLWithPath: "/tmp/h")
        let inst = AgentInstaller(home: home, wmBinary: nil)
        #expect(inst.isBinDirOnPath("/usr/bin:/tmp/h/.local/bin"))
        #expect(!inst.isBinDirOnPath("/usr/bin"))
        let json = inst.desktopConfigJSON(wmPath: "/a/wm")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let cmd = ((obj?["mcpServers"] as? [String: Any])?["windows-manager"] as? [String: Any])?["command"] as? String
        #expect(cmd == "/a/wm")
    }
}

@Suite struct AgentInstallerConnectTests {
    private func makeHome() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("agentc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func desktop(_ home: URL, wm: String? = "/x/wm") -> AgentInstaller {
        AgentInstaller(home: home, wmBinary: wm.map { URL(fileURLWithPath: $0) })
    }
    private func writeConfig(_ inst: AgentInstaller, _ text: String) throws {
        try FileManager.default.createDirectory(at: inst.desktopDir, withIntermediateDirectories: true)
        try text.write(to: inst.desktopConfigURL, atomically: true, encoding: .utf8)
    }
    private func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    @Test func desktopConnectKeepsKeysAndBacksUp() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let inst = desktop(home)
        try writeConfig(inst, #"{"theme":"dark","mcpServers":{"other":{"command":"o"}}}"#)
        try inst.connectDesktop()
        let cfg = try json(inst.desktopConfigURL)
        #expect(cfg["theme"] as? String == "dark")
        let servers = cfg["mcpServers"] as! [String: Any]
        #expect(servers["other"] != nil)
        let ours = servers["windows-manager"] as! [String: Any]
        #expect(ours["command"] as? String == "/x/wm")
        #expect(ours["args"] as? [String] == ["mcp"])
        let bak = inst.desktopDir.appendingPathComponent("claude_desktop_config.json.bak-wm")
        #expect(FileManager.default.fileExists(atPath: bak.path))
        #expect(inst.desktopStatus() == .connected)
        // Second backup does not overwrite the first.
        try inst.connectDesktop()
        let baks = try FileManager.default.contentsOfDirectory(atPath: inst.desktopDir.path).filter { $0.contains("bak-wm") }
        #expect(baks.count == 2)
        let first = try json(bak)
        #expect((first["mcpServers"] as! [String: Any])["windows-manager"] == nil)
    }

    @Test func desktopDisconnectRemovesOnlyOurKey() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let inst = desktop(home)
        try writeConfig(inst, #"{"a":1,"mcpServers":{"other":{"command":"o"}}}"#)
        try inst.connectDesktop()
        try inst.disconnectDesktop()
        let cfg = try json(inst.desktopConfigURL)
        #expect(cfg["a"] as? Int == 1)
        let servers = cfg["mcpServers"] as! [String: Any]
        #expect(servers.keys.sorted() == ["other"])
        #expect(inst.desktopStatus() == .notConnected)
    }

    @Test func desktopCreatesMissingConfig() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let inst = desktop(home)
        try FileManager.default.createDirectory(at: inst.desktopDir, withIntermediateDirectories: true)
        try inst.connectDesktop()
        #expect(inst.desktopStatus() == .connected)
    }

    @Test func invalidJSONRefusedUnchanged() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let inst = desktop(home)
        try writeConfig(inst, "{ not json")
        #expect(throws: AgentInstallError.self) { try inst.connectDesktop() }
        #expect(throws: AgentInstallError.self) { try inst.disconnectDesktop() }
        #expect(try String(contentsOf: inst.desktopConfigURL, encoding: .utf8) == "{ not json")
        let files = try FileManager.default.contentsOfDirectory(atPath: inst.desktopDir.path)
        #expect(files == ["claude_desktop_config.json"])
    }

    @Test func desktopStatusVariants() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let inst = desktop(home)
        #expect(inst.desktopStatus() == .claudeNotInstalled)
        try FileManager.default.createDirectory(at: inst.desktopDir, withIntermediateDirectories: true)
        #expect(inst.desktopStatus() == .notConnected)
        try writeConfig(inst, #"{"mcpServers":{"windows-manager":{"command":"/old/wm","args":["mcp"]}}}"#)
        #expect(inst.desktopStatus() == .connectedOtherPath("/old/wm"))
        try inst.connectDesktop()
        #expect(inst.desktopStatus() == .connected)
    }

    @Test func desktopWithoutWmFails() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let inst = desktop(home, wm: nil)
        #expect(throws: AgentInstallError.self) { try inst.connectDesktop() }
    }

    final class Calls: @unchecked Sendable {
        var list: [[String]] = []
        var getStatus: Int32 = 1
    }

    private func codeInstaller(_ home: URL, _ calls: Calls, claude: Bool = true) -> AgentInstaller {
        AgentInstaller(home: home, wmBinary: URL(fileURLWithPath: "/x/wm"), runner: { exe, args in
            if exe == "/bin/zsh" { return .init(status: claude ? 0 : 1, output: claude ? "/fake/claude\n" : "") }
            calls.list.append(args)
            if args.first == "mcp", args.dropFirst().first == "get" {
                return .init(status: calls.getStatus, output: calls.getStatus == 0 ? "windows-manager:\n" : "No MCP server found")
            }
            return .init(status: 0, output: "")
        }, isExecutable: { $0 == "/fake/claude" })
    }

    @Test func codeConnectAddsWithArgs() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let calls = Calls()
        let inst = codeInstaller(home, calls)
        #expect(inst.codeStatus() == .notConnected)
        calls.list = []
        try inst.connectCode()
        #expect(calls.list.last == ["mcp", "add", "--scope", "user", "windows-manager", "--", "/x/wm", "mcp"])
        #expect(!calls.list.contains { $0.contains("remove") })
    }

    @Test func codeConnectRemovesExistingFirst() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let calls = Calls(); calls.getStatus = 0
        let inst = codeInstaller(home, calls)
        #expect(inst.codeStatus() == .connected)
        calls.list = []
        try inst.connectCode()
        let removeIdx = calls.list.firstIndex(of: ["mcp", "remove", "--scope", "user", "windows-manager"])
        let addIdx = calls.list.firstIndex { $0.contains("add") }
        #expect(removeIdx != nil && addIdx != nil && removeIdx! < addIdx!)
    }

    @Test func codeDisconnectAndMissingCLI() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let calls = Calls()
        try codeInstaller(home, calls).disconnectCode()
        #expect(calls.list == [["mcp", "remove", "--scope", "user", "windows-manager"]])
        let none = codeInstaller(home, Calls(), claude: false)
        #expect(none.codeStatus() == .cliMissing)
        #expect(throws: AgentInstallError.self) { try none.connectCode() }
    }
}
