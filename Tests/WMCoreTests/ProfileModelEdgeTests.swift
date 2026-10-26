import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Edge cases of the profile model: empty profiles, old or partial JSON, app identity, and the
/// consistency checks that `ProfileStoreTests` does not reach.
@Suite struct ProfileModelEdgeTests {
    static let displayUUID = "EDGE0000-0000-4000-8000-0000000000D1"
    static let otherDisplayUUID = "EDGE0000-0000-4000-8000-0000000000D2"

    static let display = DisplayIdentity(
        uuid: displayUUID, name: "Edge Display", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055), isMain: true, isBuiltIn: true)

    static func wid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", n))!
    }

    static func app(_ name: String, _ bundleID: String?) -> AppRef {
        AppRef(bundleID: bundleID, name: name)
    }

    static func window(_ n: Int, _ app: AppRef, display uuid: String = displayUUID,
                       index: Int = 0, placement: SpacePlacement = .desktop(number: 1)) -> WindowSnapshot {
        WindowSnapshot(id: wid(n), app: app, indexInApp: index, displayUUID: uuid,
                       frame: CGRect(x: 10, y: 10, width: 300, height: 200),
                       relativeFrame: CGRect(x: 0, y: 0, width: 0.2, height: 0.3),
                       placement: placement, isFullScreen: false, isMinimized: false, zIndex: n)
    }

    static func profile(windows: [WindowSnapshot] = [], spaces: [SpaceSnapshot] = [],
                        displays: [DisplayIdentity] = [display]) -> Profile {
        Profile(name: "Edge", monitorSetKey: "edge", displays: displays, spaces: spaces, windows: windows)
    }

    static func jsonObject(_ profile: Profile) throws -> [String: Any] {
        let data = try ProfileStore.encode(profile)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Empty profile

    @Test func emptyProfileHasNoProblemsAndNoApps() {
        let empty = Self.profile()
        #expect(empty.validate().isEmpty)
        #expect(empty.apps.isEmpty)
        #expect(empty.windows(for: Self.app("Anything", nil)).isEmpty)
        #expect(empty.spaces(onDisplay: Self.displayUUID).isEmpty)
        #expect(empty.options == ProfileOptions())
        #expect(empty.icon == Profile.defaultIcon)
    }

    @Test func emptyProfileRoundTripsThroughTheStoreCodec() throws {
        // Whole-second dates: the store writes ISO 8601 without fractions.
        let empty = Profile(name: "Edge", createdAt: Date(timeIntervalSince1970: 1_761_400_000),
                            monitorSetKey: "edge")
        let decoded = try ProfileStore.decode(try ProfileStore.encode(empty))
        #expect(decoded == empty)
    }

    @Test func updatedAtDefaultsToCreatedAt() {
        let created = Date(timeIntervalSince1970: 1_761_400_000)
        let profile = Profile(name: "Clock", createdAt: created, monitorSetKey: "k")
        #expect(profile.updatedAt == created)
        #expect(profile.schemaVersion == Profile.currentSchemaVersion)
        #expect(profile.stageManagerOn == nil)
    }

    // MARK: Old and partial JSON

    @Test func emptyOptionsObjectDecodesToDefaults() throws {
        let data = Data("{}".utf8)
        let options = try JSONDecoder().decode(ProfileOptions.self, from: data)
        #expect(options == ProfileOptions())
        #expect(options.otherApps == .leave)
        #expect(options.hotkey == nil)
    }

    @Test func optionsWithOnlyOneKeyKeepTheRestAtDefaults() throws {
        let options = try JSONDecoder().decode(ProfileOptions.self, from: Data(#"{"otherApps":"quit"}"#.utf8))
        #expect(options.otherApps == .quit)
        #expect(options.launchMissingApps)
        #expect(options.restoreSpaceOrder)
    }

    @Test func spaceSnapshotWithoutOptionalFieldsDecodes() throws {
        let json = #"{"displayUUID":"\#(Self.displayUUID)","position":3,"kind":"fullScreen"}"#
        let space = try JSONDecoder().decode(SpaceSnapshot.self, from: Data(json.utf8))
        #expect(space.desktopNumber == nil)
        #expect(space.fullScreenWindowIDs.isEmpty)
        #expect(space.kind == .fullScreen)
        #expect(!space.isSplitView)
    }

    @Test func windowSnapshotWithoutOptionalFieldsDecodesWithDefaults() throws {
        let json = """
        {"id":"\(Self.wid(1).uuidString)","app":{"name":"Notes"},"indexInApp":0,
         "displayUUID":"\(Self.displayUUID)","frame":[[1,2],[3,4]],"relativeFrame":[[0,0],[1,1]],
         "placement":{"desktop":{"number":2}},"isFullScreen":false,"isMinimized":true,"zIndex":4}
        """
        let window = try JSONDecoder().decode(WindowSnapshot.self, from: Data(json.utf8))
        #expect(window.restore)
        #expect(window.titleMatch == .any)
        #expect(window.documentPath == nil)
        #expect(window.title == nil)
        #expect(window.isMinimized)
        #expect(window.placement == .desktop(number: 2))
    }

    @Test func unknownTitleMatchKindIsRejected() {
        let json = #"{"kind":"fuzzy","value":"x"}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TitleMatch.self, from: Data(json.utf8))
        }
    }

    @Test func titleMatchRuleWithoutItsValueIsRejected() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TitleMatch.self, from: Data(#"{"kind":"exact"}"#.utf8))
        }
    }

    @Test func newerUnknownKeysAreIgnored() throws {
        var object = try Self.jsonObject(Self.profile(windows: [Self.window(1, Self.app("Notes", "com.apple.Notes"))]))
        object["someFutureField"] = ["anything": 1]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try ProfileStore.decode(data)
        #expect(decoded.windows.count == 1)
        #expect(decoded.name == "Edge")
    }

    @Test func absentOptionalProfileKeysAreNotWrittenAsNull() throws {
        let object = try Self.jsonObject(Self.profile())
        #expect(object["notes"] == nil)
        #expect(object["stageManagerOn"] == nil)
    }

    // MARK: Split View and Space identity

    @Test func splitViewNeedsAFullScreenSpaceWithTwoWindows() {
        let a = Self.wid(1), b = Self.wid(2)
        #expect(SpaceSnapshot(displayUUID: Self.displayUUID, position: 0, kind: .fullScreen,
                              fullScreenWindowIDs: [a, b]).isSplitView)
        #expect(!SpaceSnapshot(displayUUID: Self.displayUUID, position: 0, kind: .fullScreen,
                               fullScreenWindowIDs: [a]).isSplitView)
        #expect(!SpaceSnapshot(displayUUID: Self.displayUUID, position: 0, kind: .fullScreen).isSplitView)
        // Two ids on a Desktop are not a Split View.
        #expect(!SpaceSnapshot(displayUUID: Self.displayUUID, position: 0, kind: .desktop,
                               fullScreenWindowIDs: [a, b]).isSplitView)
    }

    @Test func spaceIdentityIsDisplayAndPosition() {
        let first = SpaceSnapshot(displayUUID: Self.displayUUID, position: 1, kind: .desktop, desktopNumber: 1)
        let sameSlot = SpaceSnapshot(displayUUID: Self.displayUUID, position: 1, kind: .fullScreen)
        let otherDisplay = SpaceSnapshot(displayUUID: Self.otherDisplayUUID, position: 1, kind: .desktop)
        #expect(first.id == sameSlot.id)
        #expect(first.id != otherDisplay.id)
    }

    @Test func spacesOnDisplaySortByPositionAndIgnoreOtherMonitors() {
        let spaces = [
            SpaceSnapshot(displayUUID: Self.otherDisplayUUID, position: 0, kind: .desktop),
            SpaceSnapshot(displayUUID: Self.displayUUID, position: 2, kind: .desktop),
            SpaceSnapshot(displayUUID: Self.displayUUID, position: 0, kind: .fullScreen),
        ]
        let profile = Self.profile(spaces: spaces)
        let positions = profile.spaces(onDisplay: Self.displayUUID).map(\.position)
        #expect(positions == [0, 2])
        #expect(profile.spaces(onDisplay: "NOPE").isEmpty)
    }

    // MARK: App identity

    @Test func sameBundleIDWithDifferentNamesIsOneApp() {
        let profile = Self.profile(windows: [
            Self.window(1, Self.app("Chrome", "com.google.Chrome")),
            Self.window(2, Self.app("Google Chrome", "com.google.Chrome")),
        ])
        #expect(profile.apps.count == 1)
        #expect(profile.apps.first?.name == "Chrome")
        #expect(profile.windows(for: Self.app("Whatever", "com.google.Chrome")).count == 2)
    }

    @Test func sameNameWithDifferentBundleIDsIsTwoApps() {
        let profile = Self.profile(windows: [
            Self.window(1, Self.app("Tool", "com.one.tool")),
            Self.window(2, Self.app("Tool", "com.two.tool")),
        ])
        #expect(profile.apps.count == 2)
        #expect(profile.windows(for: Self.app("Tool", "com.one.tool")).map(\.id) == [Self.wid(1)])
    }

    @Test func bundlelessAppsCompareByNameIgnoringCase() {
        let profile = Self.profile(windows: [
            Self.window(1, Self.app("Old Tool", nil)),
            Self.window(2, Self.app("OLD TOOL", nil)),
        ])
        #expect(profile.apps.count == 1)
        #expect(profile.windows(for: Self.app("old tool", nil)).count == 2)
    }

    @Test func windowsOfOneAppKeepInputOrderWhenIndexesTie() {
        let chrome = Self.app("Chrome", "com.google.Chrome")
        let profile = Self.profile(windows: [
            Self.window(3, chrome, index: 1),
            Self.window(1, chrome, index: 0),
            Self.window(2, chrome, index: 0),
        ])
        #expect(profile.windows(for: chrome).map(\.id) == [Self.wid(1), Self.wid(2), Self.wid(3)])
    }

    @Test func appsKeepFirstSeenOrder() {
        let notes = Self.app("Notes", "com.apple.Notes")
        let chrome = Self.app("Chrome", "com.google.Chrome")
        let profile = Self.profile(windows: [
            Self.window(1, chrome), Self.window(2, notes), Self.window(3, chrome),
        ])
        #expect(profile.apps.map(\.name) == ["Chrome", "Notes"])
    }

    // MARK: validate() beyond the store tests

    @Test func validateReportsWindowsOnUnlistedDisplays() {
        var profile = Self.profile(windows: [Self.window(1, Self.app("Notes", "com.apple.Notes"))])
        profile.windows[0].displayUUID = Self.otherDisplayUUID
        let problems = profile.validate()
        #expect(problems.count == 1)
        #expect(problems[0].contains("does not list"))
        #expect(problems[0].contains(Self.otherDisplayUUID))
    }

    @Test func validateReportsSpacesOnUnlistedDisplays() {
        let profile = Self.profile(spaces: [
            SpaceSnapshot(displayUUID: Self.otherDisplayUUID, position: 0, kind: .desktop, desktopNumber: 1),
        ])
        let problems = profile.validate()
        #expect(problems.count == 1)
        #expect(problems[0].contains("Space 0"))
        #expect(problems[0].contains("does not list"))
    }

    @Test func duplicateDisplayIsReportedOnce() {
        let profile = Self.profile(displays: [Self.display, Self.display, Self.display])
        let problems = profile.validate().filter { $0.contains("listed more than once") }
        #expect(problems.count == 1)
    }

    @Test func sameSpacePositionOnTwoMonitorsIsFine() {
        let other = DisplayIdentity(uuid: Self.otherDisplayUUID, name: "Second",
                                    frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                                    visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                                    isMain: false, isBuiltIn: false)
        let profile = Self.profile(spaces: [
            SpaceSnapshot(displayUUID: Self.displayUUID, position: 0, kind: .desktop, desktopNumber: 1),
            SpaceSnapshot(displayUUID: Self.otherDisplayUUID, position: 0, kind: .desktop, desktopNumber: 1),
        ], displays: [Self.display, other])
        #expect(profile.validate().isEmpty)
    }

    @Test func windowOwningThreeFullScreenSpacesIsReportedOnce() {
        let chrome = Self.app("Chrome", "com.google.Chrome")
        var profile = Self.profile(windows: [Self.window(1, chrome)], spaces: [
            SpaceSnapshot(displayUUID: Self.displayUUID, position: 0, kind: .fullScreen, fullScreenWindowIDs: [Self.wid(1)]),
            SpaceSnapshot(displayUUID: Self.displayUUID, position: 1, kind: .fullScreen, fullScreenWindowIDs: [Self.wid(1)]),
            SpaceSnapshot(displayUUID: Self.displayUUID, position: 2, kind: .fullScreen, fullScreenWindowIDs: [Self.wid(1)]),
        ])
        let problems = profile.validate().filter { $0.contains("more than one full-screen Space") }
        #expect(problems.count == 1)
        profile.spaces = []
        #expect(profile.validate().isEmpty)
    }

    @Test func whitespaceOnlyNameIsReportedAndOtherProblemsStillListed() {
        var profile = Self.profile(windows: [Self.window(1, Self.app("Notes", "com.apple.Notes"))])
        profile.name = " \t "
        profile.windows[0].displayUUID = Self.otherDisplayUUID
        let problems = profile.validate()
        #expect(problems.contains { $0.contains("name is empty") })
        #expect(problems.contains { $0.contains("does not list") })
    }
}
