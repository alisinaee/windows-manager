import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite("Power-user debug fixtures")
struct DebugFixturesTests {
    static let expectedIDs = [
        "deep-work", "meetings", "vpn-tools", "design-2mon", "home-work-work", "home-work-home",
        "partial", "mixed-states", "dupes", "slow-front", "twice-minsize",
    ]

    /// Scenarios that place windows on purpose outside their display (negative coordinates).
    static let offscreenByDesign: Set<String> = ["design-2mon"]

    @Test func everyScenarioHasAUniqueStableID() {
        let ids = DebugFixtures.scenarios.map(\.id)
        #expect(ids.count == 11)
        #expect(ids == Self.expectedIDs)
        #expect(Set(ids).count == ids.count)
        #expect(DebugFixtures.scenarios.map(\.title).allSatisfy { !$0.isEmpty })
    }

    @Test func everySpecBuildsAValidProfile() {
        let displays = DebugFixtures.syntheticDisplays(count: 2)
        for spec in DebugFixtures.scenarios {
            guard let profile = DebugFixtures.profile(for: spec.id, displays: displays) else {
                Issue.record("no profile for \(spec.id)")
                continue
            }
            #expect(profile.schemaVersion == Profile.currentSchemaVersion, "\(spec.id)")
            #expect(profile.name == DebugFixtures.namePrefix + spec.title, "\(spec.id)")
            #expect(!profile.windows.isEmpty, "\(spec.id) has no windows")
            #expect(profile.monitorSetKey == DisplayMap.monitorSetKey(displays), "\(spec.id)")
            #expect(Set(profile.windows.map(\.id)).count == profile.windows.count, "\(spec.id) duplicate window ids")
            // Every window must reference a display of the profile.
            let uuids = Set(displays.map(\.uuid))
            #expect(profile.windows.allSatisfy { uuids.contains($0.displayUUID) }, "\(spec.id)")
            // Round-trips through the store's JSON encoding.
            let data = try? ProfileStore.encode(profile)
            #expect(data != nil, "\(spec.id) does not encode")
            if let data { #expect((try? ProfileStore.decode(data)) == profile, "\(spec.id) does not round-trip") }
        }
    }

    @Test func profileNamesAreUnique() {
        let names = DebugFixtures.profiles(displays: DebugFixtures.syntheticDisplays(count: 2)).map(\.profile.name)
        #expect(names.count == 11)
        #expect(Set(names).count == names.count)
    }

    @Test func desktopNumbersAreContiguousPerDisplay() {
        for (spec, profile) in DebugFixtures.profiles(displays: DebugFixtures.syntheticDisplays(count: 2)) {
            for display in profile.displays {
                let desktops = profile.spaces.filter { $0.displayUUID == display.uuid && $0.kind == .desktop }
                let numbers = desktops.compactMap(\.desktopNumber).sorted()
                #expect(numbers == Array(stride(from: 1, through: numbers.count, by: 1)),
                        "\(spec.id) desktops on \(display.uuid) are \(numbers)")
                let positions = profile.spaces.filter { $0.displayUUID == display.uuid }.map(\.position).sorted()
                #expect(positions == Array(0..<positions.count), "\(spec.id) positions \(positions)")
            }
            for window in profile.windows {
                if case .desktop(let number) = window.placement {
                    let count = profile.spaces.filter { $0.displayUUID == window.displayUUID && $0.kind == .desktop }.count
                    #expect(number >= 1 && number <= count, "\(spec.id) \(window.app.bundleID) on desktop \(number) of \(count)")
                }
            }
        }
    }

    @Test func specsMatchTheirProfiles() {
        let displays = DebugFixtures.syntheticDisplays(count: 2)
        for spec in DebugFixtures.scenarios {
            guard let profile = DebugFixtures.profile(for: spec.id, displays: displays) else { continue }
            let used = Set(profile.windows.map(\.app.bundleID))
            #expect(used == Set(spec.requiredBundleIDs), "\(spec.id) bundle ids")
            #expect(Set(spec.expectsSizeLimited).isSubset(of: used), "\(spec.id) size-limited apps not in profile")
            let maxDesktop = profile.windows.compactMap { w -> Int? in
                if case .desktop(let n) = w.placement { return n }
                return nil
            }.max() ?? 0
            let maxSpaceDesktop = profile.spaces.compactMap(\.desktopNumber).max() ?? 0
            #expect(max(maxDesktop, maxSpaceDesktop) == spec.requiredDesktops, "\(spec.id) desktops")
            let usedDisplays = Set(profile.windows.map(\.displayUUID)).count
            #expect(spec.requiredDisplays >= usedDisplays && spec.requiredDisplays <= displays.count,
                    "\(spec.id) displays")
        }
        #expect(DebugFixtures.spec(id: "vpn-tools")?.expectsIdempotent == true)
        #expect(DebugFixtures.spec(id: "twice-minsize")?.expectsIdempotent == true)
        #expect(DebugFixtures.spec(id: "twice-minsize")?.expectsSizeLimited == [DebugFixtures.textEdit])
        #expect(DebugFixtures.spec(id: "deep-work")?.expectsIdempotent == false)
    }

    @Test func framesStayInsideTheDisplay() {
        // The fixtures are designed for a 2560 x 1440 display; each window must sit inside its own display.
        let displays = DebugFixtures.syntheticDisplays(count: 2)
        for spec in DebugFixtures.scenarios where !Self.offscreenByDesign.contains(spec.id) {
            guard let profile = DebugFixtures.profile(for: spec.id, displays: displays) else { continue }
            for window in profile.windows {
                let display = displays.first { $0.uuid == window.displayUUID }!
                #expect(display.frame.width == 2560 && display.frame.height == 1440)
                let inside = display.frame.contains(window.frame)
                #expect(inside, "\(spec.id) \(window.app.bundleID) frame \(window.frame) outside \(display.frame)")
                #expect(window.frame.width > 0 && window.frame.height > 0)
            }
        }
    }

    @Test func designTwoMonitorsDeliberatelyPlacesWindowsOffscreen() {
        let displays = DebugFixtures.syntheticDisplays(count: 2)
        let profile = DebugFixtures.profile(for: "design-2mon", displays: displays)!
        #expect(profile.windows.contains { $0.frame.minX < 0 || $0.frame.minY < 0 })
    }

    @Test func fullScreenSafariOwnsItsSpace() {
        let profile = DebugFixtures.profile(for: "mixed-states", displays: DebugFixtures.syntheticDisplays(count: 1))!
        let safari = profile.windows.first { $0.app.bundleID == DebugFixtures.safari }!
        #expect(safari.isFullScreen)
        let space = profile.spaces.first { $0.kind == .fullScreen }
        #expect(space?.fullScreenWindowIDs == [safari.id])
        #expect(profile.windows.first { $0.app.bundleID == DebugFixtures.notes }?.isMinimized == true)
    }

    @Test func partialUsesOnlyDisplayTwo() {
        let displays = DebugFixtures.syntheticDisplays(count: 2)
        let profile = DebugFixtures.profile(for: "partial", displays: displays)!
        #expect(profile.windows.allSatisfy { $0.displayUUID == displays[1].uuid })
        #expect(profile.spaces.allSatisfy { $0.displayUUID == displays[1].uuid })
    }

    @Test func homeAndWorkShareCalculatorOnAllDesktops() {
        let displays = DebugFixtures.syntheticDisplays(count: 1)
        for id in ["home-work-work", "home-work-home"] {
            let profile = DebugFixtures.profile(for: id, displays: displays)!
            let calc = profile.windows.first { $0.app.bundleID == DebugFixtures.calculator }
            #expect(calc?.placement == .allDesktops, "\(id)")
        }
    }

    @Test func duplicatesShareTitlesAndFolder() {
        let profile = DebugFixtures.profile(for: "dupes", displays: DebugFixtures.syntheticDisplays(count: 1))!
        let edits = profile.windows.filter { $0.app.bundleID == DebugFixtures.textEdit }
        #expect(edits.count == 3)
        #expect(Set(edits.map(\.indexInApp)).count == 3)
        let finders = profile.windows.filter { $0.app.bundleID == DebugFixtures.finder }
        #expect(finders.count == 2)
        #expect(Set(finders.compactMap(\.documentPath)).count == 1)
    }

    @Test func unknownIDsHaveNoProfile() {
        #expect(DebugFixtures.profile(for: "nope") == nil)
        #expect(DebugFixtures.spec(id: "nope") == nil)
    }

    @Test func missingAppsSkipTheScenario() {
        let spec = DebugFixtures.spec(id: "vpn-tools")!
        #expect(DebugFixtures.isSkipped(spec, installed: []))
        #expect(!DebugFixtures.isSkipped(spec, installed: Set(spec.requiredBundleIDs)))
        #expect(DebugFixtures.isSkipped(spec, installed: [DebugFixtures.calculator]))
    }

    @Test func availableBundleIDsIsASubsetOfTheCandidates() {
        let candidates = ["com.apple.TextEdit", "com.example.definitely-not-installed"]
        let found = DebugFixtures.availableBundleIDs(candidates)
        #expect(found.isSubset(of: Set(candidates)))
        #expect(!found.contains("com.example.definitely-not-installed"))
    }

    @Test func installReplacesInsteadOfDuplicating() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("debug-fixtures-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ProfileStore(folder: folder)
        let displays = DebugFixtures.syntheticDisplays(count: 2)
        let first = try DebugFixtures.installPowerUserFixtures(into: store, displays: displays)
        #expect(first.count == DebugFixtures.scenarios.count)
        let second = try DebugFixtures.installPowerUserFixtures(into: store, displays: displays)
        #expect(second.map(\.id) == first.map(\.id))
        #expect(store.list().count == DebugFixtures.scenarios.count)
    }
}
