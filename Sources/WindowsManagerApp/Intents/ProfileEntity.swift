// Shortcuts discovery note: App Intents metadata (Metadata.appintents) is extracted by Xcode's build
// tooling. With a plain SwiftPM / Command Line Tools build this code compiles and links, but Shortcuts
// will only list the actions once the app is built into a bundle by Xcode (appintentsmetadataprocessor).
import AppIntents
import WMCore

/// A saved profile, as Shortcuts sees it.
struct ProfileEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Profile")
    static let defaultQuery = ProfileEntityQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ summary: ProfileSummary) {
        self.id = summary.id
        self.name = summary.name
    }
}

struct ProfileEntityQuery: EntityStringQuery {
    private static func all() -> [ProfileEntity] {
        ProfileStore().list()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(ProfileEntity.init)
    }

    func entities(for identifiers: [UUID]) async throws -> [ProfileEntity] {
        Self.all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ProfileEntity] {
        Self.all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [ProfileEntity] { Self.all() }
}
