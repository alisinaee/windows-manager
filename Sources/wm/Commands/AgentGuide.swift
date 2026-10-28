import Foundation
import WMCore

func registerAgentGuideCommands(_ r: Registry) {
    r.register(Command(["agent-guide"], summary: "Markdown guide for AI agents (safety, recipes, exit codes); --json gives {markdown}") { _, _ in
        CLIResult(data: .object(["markdown": .string(agentGuideMarkdown)]), text: agentGuideMarkdown)
    })
}
