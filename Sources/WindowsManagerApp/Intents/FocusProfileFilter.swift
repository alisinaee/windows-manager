import AppIntents

/// Focus filter: choose a profile that runs when the Focus turns on.
struct FocusProfileFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Run Windows Manager profile"
    static let description: IntentDescription? = IntentDescription("Restores a profile when this Focus turns on.")

    @Parameter(title: "Profile")
    var profile: ProfileEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(profile?.name ?? "No profile")")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Runs when the Focus turns on (or the filter changes); nothing to do without a profile.
        if let profile { _ = await IntentRunner.perform(.run(profile: profile.name)) }
        return .result()
    }
}
