import Testing
import Foundation

/// The app installs AgentSkillText.skill (a Swift copy of skills/wm-agent/SKILL.md). This keeps the copy in sync.
@Suite struct AgentSkillTextSyncTests {
    @Test func swiftCopyContainsSkillFileText() throws {
        // This file is Tests/WMCoreTests/AgentSkillTextSyncTests.swift, so the repo root is three levels up.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let skill = try String(contentsOf: root.appendingPathComponent("skills/wm-agent/SKILL.md"), encoding: .utf8)
        let swift = try String(contentsOf: root.appendingPathComponent("Sources/WindowsManagerApp/Settings/AgentSkillText.swift"), encoding: .utf8)
        #expect(!skill.isEmpty)
        #expect(swift.contains(skill), "AgentSkillText.swift must match skills/wm-agent/SKILL.md exactly")
    }
}
