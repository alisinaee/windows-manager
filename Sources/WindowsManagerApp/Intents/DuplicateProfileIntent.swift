import AppIntents
import WMCore

struct DuplicateProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Duplicate Windows Manager profile"
    static let description = IntentDescription("Saves a copy of a profile under a new name.")
    static let openAppWhenRun = false

    @Parameter(title: "Profile")
    var profile: ProfileEntity

    @Parameter(title: "New name")
    var newName: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ProfileEntity> & ProvidesDialog {
        let copy = try ProfileService().copy(profile.id.uuidString, name: newName)
        AppState.current?.reloadProfiles()
        let entity = ProfileEntity(id: copy.id, name: copy.name)
        return .result(value: entity, dialog: IntentDialog(stringLiteral: "Duplicated \(profile.name) as \(copy.name)."))
    }
}
