import CoreGraphics
import Foundation
import Testing
@testable import WMCore

private let xcode = AppRef(bundleID: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")
private let slack = AppRef(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", path: nil)
private let music = AppRef(bundleID: nil, name: "Music", path: nil)

/// Tests for the PM1 model fields: `LaunchPlan`, `WindowOrigin`, `zoneName` and `addMissingDesktops`.
/// Old files (no new keys) must still decode, and must re-encode with exactly the same bytes.
@Suite struct ProfileLaunchPlanModelTests {
    // MARK: Fixtures

    /// A profile as written before PM1: no launchPlan, no origin, no zoneName, no addMissingDesktops.
    static let oldProfileJSON = #"""
    {
      "createdAt" : "2026-10-25T12:00:00Z",
      "displays" : [],
      "icon" : "rectangle.3.group",
      "id" : "0A1B2C3D-0000-4000-8000-00000000F00D",
      "monitorSetKey" : "single-built-in",
      "name" : "Old",
      "notes" : "Written before the Profile Studio.",
      "options" : {
        "hotkey" : "ctrl+opt+1",
        "launchMissingApps" : true,
        "otherApps" : "leave",
        "restoreFullScreen" : true,
        "restoreSpaceOrder" : true,
        "restoreSpaces" : true
      },
      "schemaVersion" : 1,
      "spaces" : [],
      "updatedAt" : "2026-10-25T12:00:00Z",
      "windows" : []
    }
    """#

    /// A profile that uses every new field.
    static func profileWithEveryNewField() -> Profile {
        let plan = LaunchPlan(mode: .parallel, items: [
            LaunchItem(app: xcode, enabled: true, wait: .appReady, delayAfter: 2.5, timeout: 30, activates: true),
            LaunchItem(app: slack, enabled: false),
            LaunchItem(app: music, withoutWindows: true),
        ])
        let planned = WindowSnapshot(
            app: xcode, displayUUID: "DISPLAY-A", frame: CGRect(x: 0, y: 0, width: 960, height: 1000),
            relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 1), placement: .desktop(number: 2),
            origin: .planned, zoneName: "Left half")
        let captured = WindowSnapshot(
            app: slack, displayUUID: "DISPLAY-A", frame: CGRect(x: 960, y: 0, width: 960, height: 1000),
            relativeFrame: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), placement: .desktop(number: 1),
            origin: .captured)
        return Profile(name: "Every field", createdAt: ProfileStoreTests.t0, monitorSetKey: "one", displays: [],
                        spaces: [], windows: [planned, captured],
                        options: ProfileOptions(addMissingDesktops: true), stageManagerOn: nil, launchPlan: plan)
    }

    // MARK: Old files

    @Test func oldProfileDecodesWithNewFieldsAbsent() throws {
        let profile = try ProfileStore.decode(Data(Self.oldProfileJSON.utf8))
        #expect(profile.launchPlan == nil)
        #expect(profile.options.addMissingDesktops == false)
        #expect(profile.options.hotkey == "ctrl+opt+1")
        #expect(profile.launchApps.isEmpty)
    }

    @Test func oldFixtureReencodesByteIdentical() throws {
        // The ProfileStoreTests fixture has no new fields set, so its bytes are what an old build wrote.
        let original = ProfileStoreTests.makeProfile()
        let old = try ProfileStore.encode(original)
        let text = String(decoding: old, as: UTF8.self)
        for key in ["launchPlan", "origin", "zoneName", "addMissingDesktops"] {
            #expect(!text.contains("\"\(key)\""), "\(key) must not be written when unset")
        }
        let decoded = try ProfileStore.decode(old)
        #expect(decoded == original)
        #expect(try ProfileStore.encode(decoded) == old)
    }

    @Test func literalOldJSONReencodesWithoutNewKeys() throws {
        let profile = try ProfileStore.decode(Data(Self.oldProfileJSON.utf8))
        let text = String(decoding: try ProfileStore.encode(profile), as: UTF8.self)
        #expect(!text.contains("addMissingDesktops"))
        #expect(!text.contains("launchPlan"))
        // A second round trip is stable too.
        let again = try ProfileStore.encode(try ProfileStore.decode(try ProfileStore.encode(profile)))
        #expect(again == (try ProfileStore.encode(profile)))
    }

    // MARK: Round trip

    @Test func profileWithEveryNewFieldRoundTrips() throws {
        let profile = Self.profileWithEveryNewField()
        let data = try ProfileStore.encode(profile)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["launchPlan", "addMissingDesktops", "appReady", "planned", "captured", "zoneName"] {
            #expect(text.contains(key), "\(key) should be written")
        }
        let decoded = try ProfileStore.decode(data)
        #expect(decoded == profile)
        #expect(decoded.launchPlan?.mode == .parallel)
        #expect(decoded.launchPlan?.items.first?.delayAfter == 2.5)
        #expect(decoded.windows.map(\.origin) == [.planned, .captured])
        #expect(decoded.windows.first?.zoneName == "Left half")
        #expect(decoded.options.addMissingDesktops)
        #expect(try ProfileStore.encode(decoded) == data)
    }

    @Test func addMissingDesktopsIsWrittenOnlyWhenTrue() throws {
        let off = String(decoding: try JSONEncoder().encode(ProfileOptions()), as: UTF8.self)
        #expect(!off.contains("addMissingDesktops"))
        let on = try JSONEncoder().encode(ProfileOptions(addMissingDesktops: true))
        #expect(String(decoding: on, as: UTF8.self).contains("\"addMissingDesktops\":true"))
        #expect(try JSONDecoder().decode(ProfileOptions.self, from: on).addMissingDesktops)
    }

    // MARK: Defaults

    @Test func launchPlanDefaults() throws {
        let plan = LaunchPlan()
        #expect(plan.mode == .sequential)
        #expect(plan.items.isEmpty)

        let item = LaunchItem(app: xcode)
        #expect(item.enabled)
        #expect(item.wait == .windows)
        #expect(item.delayAfter == 0)
        #expect(item.timeout == nil)
        #expect(!item.activates)
        #expect(!item.withoutWindows)

        // A hand-written item with only the app gets the same defaults.
        let minimal = try JSONDecoder().decode(LaunchItem.self, from: Data(#"{"app":{"name":"Xcode"}}"#.utf8))
        #expect(minimal.enabled)
        #expect(minimal.wait == .windows)
        #expect(minimal.delayAfter == 0)
        #expect(minimal.timeout == nil)

        let emptyPlan = try JSONDecoder().decode(LaunchPlan.self, from: Data("{}".utf8))
        #expect(emptyPlan.mode == .sequential)
        #expect(emptyPlan.items.isEmpty)
    }

    @Test func launchItemIdentityFollowsTheApp() {
        #expect(LaunchItem(app: xcode).id == "com.apple.dt.xcode")
        #expect(LaunchItem(app: music).id == "name:music")
        #expect(LaunchItem(app: AppRef(bundleID: "", name: "Notes")).id == "name:notes")
    }

    // MARK: Clamping

    @Test func delayAndTimeoutAreClampedWhenCreated() {
        #expect(LaunchItem(app: xcode, delayAfter: 500).delayAfter == 60)
        #expect(LaunchItem(app: xcode, delayAfter: -3).delayAfter == 0)
        #expect(LaunchItem(app: xcode, delayAfter: .nan).delayAfter == 0)
        #expect(LaunchItem(app: xcode, delayAfter: 12.5).delayAfter == 12.5)

        #expect(LaunchItem(app: xcode, timeout: 1).timeout == 5)
        #expect(LaunchItem(app: xcode, timeout: 999).timeout == 120)
        #expect(LaunchItem(app: xcode, timeout: nil).timeout == nil)
        #expect(LaunchItem(app: xcode, timeout: .infinity).timeout == nil)
        #expect(LaunchItem(app: xcode, timeout: 45).timeout == 45)
    }

    @Test func delayAndTimeoutAreClampedWhenSet() {
        var item = LaunchItem(app: xcode)
        item.delayAfter = 75
        #expect(item.delayAfter == 60)
        item.timeout = 0
        #expect(item.timeout == 5)
        item.timeout = nil
        #expect(item.timeout == nil)
    }

    @Test func delayAndTimeoutAreClampedWhenDecoded() throws {
        let json = #"{"app":{"name":"Xcode"},"delayAfter":90,"timeout":2}"#
        let item = try JSONDecoder().decode(LaunchItem.self, from: Data(json.utf8))
        #expect(item.delayAfter == 60)
        #expect(item.timeout == 5)

        let negative = try JSONDecoder().decode(LaunchItem.self, from: Data(#"{"app":{"name":"X"},"delayAfter":-1}"#.utf8))
        #expect(negative.delayAfter == 0)
    }

    // MARK: Unknown wait value

    @Test func unknownWaitValueFailsWithAReadableError() throws {
        let json = #"{"app":{"name":"Xcode"},"wait":"sometimes"}"#
        do {
            _ = try JSONDecoder().decode(LaunchItem.self, from: Data(json.utf8))
            Issue.record("An unknown wait value must not decode")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.contains("\"sometimes\""))
            #expect(context.debugDescription.contains("appReady"))
            #expect(context.codingPath.last?.stringValue == "wait")
        }
    }

    @Test func unknownWaitInsideAProfileFailsToLoad() throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(Self.oldProfileJSON.utf8)) as? [String: Any])
        object["launchPlan"] = ["mode": "sequential", "items": [["app": ["name": "Xcode"], "wait": "immediately"]]]
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try ProfileStore.decode(data, source: "test.json")
            Issue.record("A profile with an unknown wait value must not load")
        } catch {
            #expect("\(error)".contains("immediately"))
        }
    }

    // MARK: Derived values

    @Test func launchAppsAddsLaunchOnlyAppsOnce() {
        let safari = AppRef(bundleID: "com.apple.Safari", name: "Safari", path: nil)
        let window = WindowSnapshot(app: safari, displayUUID: "DISPLAY-A", frame: .zero, relativeFrame: .zero,
                                    placement: .desktop(number: 1))
        let profile = Profile(name: "Launch", monitorSetKey: "one", windows: [window],
                              launchPlan: LaunchPlan(items: [
                                  LaunchItem(app: xcode, withoutWindows: true),
                                  LaunchItem(app: AppRef(bundleID: "com.apple.safari", name: "Safari"), withoutWindows: true),
                                  LaunchItem(app: slack),
                              ]))
        #expect(profile.launchApps.map(\.name) == ["Safari", "Xcode"])
        #expect(profile.apps.map(\.name) == ["Safari"])
    }

    @Test func windowOriginIsNilForCapturedWindowsInOldFiles() throws {
        let profile = ProfileStoreTests.makeProfile()
        let decoded = try ProfileStore.decode(try ProfileStore.encode(profile))
        #expect(decoded.windows.allSatisfy { $0.origin == nil && $0.zoneName == nil })
    }
}
