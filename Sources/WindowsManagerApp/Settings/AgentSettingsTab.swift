import AppKit
import SwiftUI
import WMCore

struct AgentSettingsTab: View {
    @State private var cli = AgentInstaller.CLIStatus.notInstalled
    @State private var skill = AgentInstaller.SkillStatus.notInstalled
    @State private var onPath = true
    @State private var message: String?

    private var installer: AgentInstaller { AgentInstaller(wmBinary: Self.bundledWM()) }

    /// The wm tool next to the app executable or in Resources; nil when this build does not ship it.
    static func bundledWM() -> URL? {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("wm"),
            Bundle.main.resourceURL?.appendingPathComponent("wm"),
        ]
        return candidates.compactMap { $0 }.first { fm.isExecutableFile(atPath: $0.path) }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { Text(cliText).foregroundStyle(.secondary) }
                HStack {
                    Button(cli == .installed ? "Reinstall" : "Install command line tool") { run { try installer.installCLI() } }
                        .disabled(cli == .sourceMissing)
                    Button("Uninstall") { run { try installer.uninstallCLI() } }
                        .disabled(cli != .installed)
                }
                if cli != .sourceMissing && !onPath {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("~/.local/bin is not on your PATH. Add this line to ~/.zshrc:")
                            .font(.wmCaption).foregroundStyle(.secondary)
                        copyRow(installer.pathHint)
                    }
                }
            } header: {
                Text("Command line tool")
            } footer: {
                Text("Links wm into ~/.local/bin. No administrator rights needed.")
            }
            Section {
                LabeledContent("Status") { Text(skillText).foregroundStyle(.secondary) }
                HStack {
                    Button(skill == .installed ? "Reinstall" : "Install Claude skill") {
                        run { try installer.installSkill(AgentSkillText.skill) }
                    }
                    Button("Uninstall") { run { try installer.uninstallSkill() } }
                        .disabled(skill == .notInstalled)
                }
            } header: {
                Text("Claude skill")
            } footer: {
                Text("Copies the wm-agent skill to ~/.claude/skills/wm-agent/SKILL.md.")
            }
            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Claude Code").font(.wmCaption).foregroundStyle(.secondary)
                    copyRow(AgentInstaller.mcpCommand)
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Claude Desktop (add to claude_desktop_config.json)").font(.wmCaption).foregroundStyle(.secondary)
                    copyRow(installer.desktopConfigJSON(wmPath: configCommandPath), multiline: true)
                }
            } header: {
                Text("Connect to Claude (MCP)")
            } footer: {
                Text("Nothing is written for you here; copy the snippet where you need it.")
            }
            if let message {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private var configCommandPath: String {
        cli == .installed ? installer.linkURL.path : (Self.bundledWM()?.path ?? installer.linkURL.path)
    }

    private var cliText: String {
        switch cli {
        case .installed: return "Installed at ~/.local/bin/wm"
        case .notInstalled: return "Not installed"
        case .pointsElsewhere(let p): return "~/.local/bin/wm points elsewhere (\(p))"
        case .sourceMissing: return "This build of the app does not include the wm tool"
        }
    }

    private var skillText: String {
        switch skill {
        case .installed: return "Installed"
        case .outdated: return "Installed, differs from this app's version"
        case .notInstalled: return "Not installed"
        }
    }

    private func copyRow(_ text: String, multiline: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); message = nil } catch { message = error.localizedDescription }
        refresh()
    }

    private func refresh() {
        let i = installer
        cli = i.cliStatus()
        skill = i.skillStatus(expected: AgentSkillText.skill)
        onPath = i.isBinDirOnPath()
    }
}
