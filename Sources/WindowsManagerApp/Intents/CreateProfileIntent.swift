import AppIntents
import WMCore

struct CreateProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Windows Manager profile"
    static let description = IntentDescription("Creates an empty profile with the given name.")
    static let openAppWhenRun = false

    @Parameter(title: "Name")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ProfileEntity> & ProvidesDialog {
        let profile = try ProfileService().createBlank(name: name, displays: DisplayMap.current())
        AppState.current?.reloadProfiles()
        let entity = ProfileEntity(id: profile.id, name: profile.name)
        return .result(value: entity, dialog: IntentDialog(stringLiteral: "Created profile \(profile.name)."))
    }
}
