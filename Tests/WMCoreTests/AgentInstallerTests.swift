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
