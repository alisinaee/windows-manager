import AppIntents

struct CaptureWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Windows Manager workspace"
    static let description = IntentDescription("Saves the current windows as a profile.")
    static let openAppWhenRun = false

    @Parameter(title: "Name")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Failed: give the profile a name.")
        }
        let outcome = await IntentRunner.perform(.capture(name: trimmed))
        return .result(dialog: IntentDialog(stringLiteral: outcome.ok ? outcome.text : "Failed: \(outcome.text)"))
    }
}
