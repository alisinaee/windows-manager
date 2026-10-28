import Foundation
import Testing
@testable import WMCore

/// The per-profile sidebar icon: old files without the key still load, and a chosen icon survives a save.
@Suite struct ProfileIconTests {
    @Test func oldJSONWithoutIconDecodesToDefaultIcon() throws {
        let profile = Profile(name: "Old", monitorSetKey: "old-icon")
        let data = try ProfileStore.encode(profile)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "icon")
        let oldData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try ProfileStore.decode(oldData, source: "old.json")

        #expect(decoded.icon == Profile.defaultIcon)
        #expect(decoded.name == "Old")
    }

    @Test func chosenIconRoundTrips() throws {
        let profile = Profile(name: "Work", icon: "briefcase", monitorSetKey: "work-icon")
        let data = try ProfileStore.encode(profile)

        let decoded = try ProfileStore.decode(data, source: "work.json")

        #expect(decoded.icon == "briefcase")
        #expect(ProfileSummary(decoded).icon == "briefcase")
    }
}
