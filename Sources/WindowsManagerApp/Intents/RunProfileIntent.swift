import AppIntents

struct RunProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Windows Manager profile"
    static let description = IntentDescription("Restores a saved Windows Manager profile.")
    static let openAppWhenRun = false

    @Parameter(title: "Profile")
    var profile: ProfileEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await IntentRunner.runProfile(id: profile.id)
        return .result(dialog: IntentDialog(stringLiteral: outcome.ok ? outcome.text : "Failed: \(outcome.text)"))
    }
}
