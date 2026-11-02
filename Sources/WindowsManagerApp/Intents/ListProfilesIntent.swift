import AppIntents

struct ListProfilesIntent: AppIntent {
    static let title: LocalizedStringResource = "List Windows Manager profiles"
    static let description = IntentDescription("Returns the saved Windows Manager profiles.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ProfileEntity]> {
        let profiles = try await ProfileEntityQuery().suggestedEntities()
        return .result(value: profiles)
    }
}
