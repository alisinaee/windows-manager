import AppIntents
import WMCore

struct VerifyProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Verify Windows Manager profile"
    static let description = IntentDescription("Counts how many windows of a saved profile match their saved places right now.")
    static let openAppWhenRun = false

    @Parameter(title: "Profile")
    var profile: ProfileEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let state = AppState.current else {
            return .result(dialog: "Failed: Windows Manager is not running. Open the app and try again.")
        }
        guard state.isAccessibilityTrusted else {
            return .result(dialog: "Failed: Windows Manager needs Accessibility permission first.")
        }
        guard !state.status.isBusy else {
            return .result(dialog: "Failed: Windows Manager is busy with another task.")
        }
        let loaded = try ProfileService().show(profile.id.uuidString)
        let plan = await RestoreEngine().preview(profile: loaded)
        let result = CLIVerifyResult(profile: loaded, plan: plan)
        let matched = result.checked - result.mismatches
        let text = "\(loaded.name): \(matched) matched, \(result.mismatches) unmatched of \(result.checked) window(s)."
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}
