import Foundation
import Testing
@testable import WMCore

/// Tests for the pure single-file profile transfer functions (P6.5).
@Suite struct ProfileTransferTests {
    static func sample(name: String = "Home", hotkey: String? = "ctrl+opt+1") -> Profile {
        var options = ProfileOptions()
        options.hotkey = hotkey
        return Profile(id: UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000C1")!, name: name,
                       createdAt: Date(timeIntervalSince1970: 1_761_400_000),
                       monitorSetKey: "one-display", options: options, notes: "desk")
    }

    static let newID = UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000D2")!

    static func json(_ profile: Profile) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: ProfileTransfer.export(profile)) as! [String: Any]
    }

    // MARK: export

    @Test func exportIsPrettyJSONWithSchemaVersion() throws {
        let data = try ProfileTransfer.export(Self.sample())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\n  "))
        let object = try Self.json(Self.sample())
        #expect(object["schemaVersion"] as? Int == Profile.currentSchemaVersion)
        #expect(object["name"] as? String == "Home")
    }

    @Test func exportThenImportRoundTripsContent() throws {
        let original = Self.sample()
        let data = try ProfileTransfer.export(original)
        let copy = try ProfileTransfer.importProfile(data, existingNames: [], newID: Self.newID)
        #expect(copy.id == Self.newID)
        #expect(copy.name == original.name)
        #expect(copy.notes == original.notes)
        #expect(copy.monitorSetKey == original.monitorSetKey)
        #expect(copy.createdAt == original.createdAt)
    }

    // MARK: import

    @Test func importClearsHotkeyBecauseItBelongsToOneProfile() throws {
        let data = try ProfileTransfer.export(Self.sample(hotkey: "ctrl+opt+1"))
        let copy = try ProfileTransfer.importProfile(data, existingNames: [], newID: Self.newID)
        #expect(copy.options.hotkey == nil)
    }

    @Test func importKeepsNameWhenFree() throws {
        let data = try ProfileTransfer.export(Self.sample(name: "Work"))
        let copy = try ProfileTransfer.importProfile(data, existingNames: ["Home"], newID: Self.newID)
        #expect(copy.name == "Work")
    }

    @Test func importRenamesWhenNameExists() throws {
        let data = try ProfileTransfer.export(Self.sample(name: "Home"))
        let copy = try ProfileTransfer.importProfile(data, existingNames: ["Home"], newID: Self.newID)
        #expect(copy.name == "Home 2")
    }

    @Test func importRejectsNewerSchemaVersion() throws {
        var object = try Self.json(Self.sample())
        object["schemaVersion"] = Profile.currentSchemaVersion + 1
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ProfileStoreError.unsupportedSchema(found: Profile.currentSchemaVersion + 1,
                                                            supported: Profile.currentSchemaVersion)) {
            try ProfileTransfer.importProfile(data, existingNames: [], newID: Self.newID)
        }
    }

    @Test func importRejectsMissingSchemaVersion() throws {
        var object = try Self.json(Self.sample())
        object["schemaVersion"] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ProfileStoreError.self) {
            try ProfileTransfer.importProfile(data, existingNames: [], newID: Self.newID)
        }
    }

    @Test func importRejectsNonJSON() {
        #expect(throws: ProfileStoreError.self) {
            try ProfileTransfer.importProfile(Data("not json".utf8), existingNames: [], newID: Self.newID)
        }
    }

    @Test func importRejectsEmptyName() throws {
        let data = try ProfileTransfer.export(Self.sample(name: "   "))
        #expect(throws: ProfileStoreError.self) {
            try ProfileTransfer.importProfile(data, existingNames: [], newID: Self.newID)
        }
    }

    // MARK: uniqueName

    @Test func uniqueNameIgnoresCaseAndSpaces() {
        #expect(ProfileTransfer.uniqueName("home", among: [" Home "]) == "home 2")
    }

    @Test func uniqueNameSkipsTakenNumbers() {
        #expect(ProfileTransfer.uniqueName("Home", among: ["Home", "Home 2"]) == "Home 3")
    }

    @Test func uniqueNameKeepsFreeNameAsIs() {
        #expect(ProfileTransfer.uniqueName("Office", among: ["Home"]) == "Office")
    }
}
