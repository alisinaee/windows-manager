import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite struct CLIScopeParserTests {
    static let studio = DisplayIdentity(uuid: "AAAA-1111", name: "Studio Display",
                                        frame: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                                        visibleFrame: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                                        isMain: true, isBuiltIn: false)
    static let dell = DisplayIdentity(uuid: "BBBB-2222", name: "Dell U2720Q",
                                      frame: CGRect(x: 2000, y: 0, width: 1000, height: 1000),
                                      visibleFrame: CGRect(x: 2000, y: 0, width: 1000, height: 1000),
                                      isMain: false, isBuiltIn: false)
    static let safari = AppRef(bundleID: "com.apple.Safari", name: "Safari")
    static let mail = AppRef(bundleID: "com.apple.mail", name: "Mail")
    static let terminal = AppRef(bundleID: "com.apple.Terminal", name: "Terminal")

    /// Studio: Desktops 1 and 2 (Safari on 1, Mail on 2). Dell: Desktop 1 only (Terminal).
    static func fixture() -> Profile {
        let spaces = [
            SpaceSnapshot(displayUUID: studio.uuid, position: 0, kind: .desktop, desktopNumber: 1),
            SpaceSnapshot(displayUUID: studio.uuid, position: 1, kind: .desktop, desktopNumber: 2),
            SpaceSnapshot(displayUUID: dell.uuid, position: 0, kind: .desktop, desktopNumber: 1),
        ]
        let windows = [
            window(safari, display: studio.uuid, desktop: 1),
            window(mail, display: studio.uuid, desktop: 2),
            window(terminal, display: dell.uuid, desktop: 1),
        ]
        return Profile(name: "Work", monitorSetKey: "two", displays: [studio, dell], spaces: spaces, windows: windows)
    }

    static func window(_ app: AppRef, display: String, desktop: Int) -> WindowSnapshot {
        WindowSnapshot(app: app, displayUUID: display, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                       relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), placement: .desktop(number: desktop),
                       isFullScreen: false, isMinimized: false)
    }

    /// The usage failure a parse throws, or nil when it succeeds.
    static func failure(_ body: () throws -> RestoreScope) -> CLIFailure? {
        do {
            _ = try body()
            return nil
        } catch let error as CLIFailure {
            return error
        } catch {
            return nil
        }
    }

    // MARK: No flags

    @Test func noFlagsIsTheWholeProfile() throws {
        let scope = try CLIScopeParser.parse(profile: Self.fixture())
        #expect(scope == .whole)
        #expect(scope.isWhole)
    }

    // MARK: Monitors

    @Test func monitorByUUIDIgnoresCase() throws {
        let scope = try CLIScopeParser.parse(profile: Self.fixture(), monitors: ["bbbb-2222"])
        #expect(scope.displays == ["BBBB-2222"])
        #expect(scope.desktops == nil)
        #expect(scope.apps == nil)
    }

    @Test func monitorByNamePartIgnoresCase() throws {
        let scope = try CLIScopeParser.parse(profile: Self.fixture(), monitors: ["dell"])
        #expect(scope.displays == ["BBBB-2222"])
    }

    @Test func monitorByOneBasedIndex() throws {
        let first = try CLIScopeParser.parse(profile: Self.fixture(), monitors: ["1"])
        #expect(first.displays == ["AAAA-1111"])
        let second = try CLIScopeParser.parse(profile: Self.fixture(), monitors: ["2"])
        #expect(second.displays == ["BBBB-2222"])
    }

    @Test func repeatedMonitorsUnion() throws {
        let scope = try CLIScopeParser.parse(profile: Self.fixture(), monitors: ["1", "Dell"])
        #expect(scope.displays == ["AAAA-1111", "BBBB-2222"])
    }

    @Test func unknownMonitorIsUsageErrorWithListingHint() throws {
        let error = try #require(Self.failure { try CLIScopeParser.parse(profile: Self.fixture(), monitors: ["Projector"]) })
        #expect(error.exit == .usage)
        #expect(error.hint?.contains("Studio Display (AAAA-1111)") == true)
        #expect(error.hint?.contains("Dell U2720Q (BBBB-2222)") == true)
    }

    @Test func indexOutOfRangeIsUsageError() throws {
        let error = try #require(Self.failure { try CLIScopeParser.parse(profile: Self.fixture(), monitors: ["3"]) })
        #expect(error.exit == .usage)
    }

    @Test func ambiguousMonitorNameIsUsageError() throws {
        let profile = Profile(name: "Twins", monitorSetKey: "twins",
                              displays: [Self.studio, DisplayIdentity(uuid: "CCCC-3333", name: "Studio Display 2",
                                                                      frame: .zero, visibleFrame: .zero,
                                                                      isMain: false, isBuiltIn: false)],
                              spaces: [SpaceSnapshot(displayUUID: "AAAA-1111", position: 0, kind: .desktop, desktopNumber: 1)],
                              windows: [Self.window(Self.safari, display: "AAAA-1111", desktop: 1)])
        let error = try #require(Self.failure { try CLIScopeParser.parse(profile: profile, monitors: ["studio"]) })
        #expect(error.exit == .usage)
    }

    // MARK: Desktops

    @Test func desktopWithoutMonitorAppliesToEveryMonitorHavingIt() throws {
        let scope = try CLIScopeParser.parse(profile: Self.fixture(), desktops: ["1"])
        #expect(scope.desktops == [
            SpaceRef(displayUUID: "AAAA-1111", desktopNumber: 1),
            SpaceRef(displayUUID: "BBBB-2222", desktopNumber: 1),
        ])
        #expect(scope.displays == nil)
    }

    @Test func desktopWithMonitorIsRelativeToThatMonitor() throws {
        let scope = try CLIScopeParser.parse(profile: Self.fixture(), monitors: ["Studio"], desktops: ["2"])
        #expect(scope.desktops == [SpaceRef(displayUUID: "AAAA-1111", desktopNumber: 2)])
        #expect(scope.displays == ["AAAA-1111"])
    }

    @Test func desktopOnOtherMonitorIsUsageError() throws {
        // Dell has no Desktop 2.
        let error = try #require(Self.failure {
            try CLIScopeParser.parse(profile: Self.fixture(), monitors: ["Dell"], desktops: ["2"])
        })
        #expect(error.exit == .usage)
        #expect(error.hint?.contains("Studio Display 1, 2") == true)
    }

    @Test func unknownDesktopIsUsageError() throws {
        let error = try #require(Self.failure { try CLIScopeParser.parse(profile: Self.fixture(), desktops: ["9"]) })
        #expect(error.exit == .usage)
        #expect(error.hint?.contains("Dell U2720Q 1") == true)
    }

    @Test func invalidDesktopNumberIsUsageError() throws {
        for raw in ["0", "-1", "two", ""] {
            let error = try #require(Self.failure { try CLIScopeParser.parse(profile: Self.fixture(), desktops: [raw]) })
            #expect(error.exit == .usage)
        }
    }

    // MARK: Apps

    @Test func appByBundleIDIgnoresCase() throws {
        let scope = try CLIScopeParser.parse(profile: Self.fixture(), apps: ["COM.APPLE.SAFARI"])
        #expect(scope.apps == ["com.apple.Safari"])
    }

    @Test func appByNamePartIgnoresCase() throws {
        let scope = try CLIScopeParser.parse(profile: Self.fixture(), apps: ["term"])
        #expect(scope.apps == ["com.apple.Terminal"])
    }

    @Test func unknownAppIsUsageErrorWithListingHint() throws {
        let error = try #require(Self.failure { try CLIScopeParser.parse(profile: Self.fixture(), apps: ["Photoshop"]) })
        #expect(error.exit == .usage)
        #expect(error.hint?.contains("Safari") == true)
        #expect(error.hint?.contains("Mail") == true)
    }

    // MARK: Combined and empty results

    @Test func monitorDesktopAndAppCombine() throws {
        let scope = try CLIScopeParser.parse(profile: Self.fixture(), monitors: ["Studio"], desktops: ["1"], apps: ["Safari"])
        #expect(scope.displays == ["AAAA-1111"])
        #expect(scope.desktops == [SpaceRef(displayUUID: "AAAA-1111", desktopNumber: 1)])
        #expect(scope.apps == ["com.apple.Safari"])
    }

    @Test func scopeSelectingNothingIsUsageError() throws {
        // Safari lives on Studio Desktop 1; asking for Mail on Dell's Desktop 1 selects nothing.
        let error = try #require(Self.failure {
            try CLIScopeParser.parse(profile: Self.fixture(), monitors: ["Dell"], apps: ["Mail"])
        })
        #expect(error.exit == .usage)
    }

    @Test func monitorWithNothingOnItIsUsageError() throws {
        let profile = Profile(name: "Bare", monitorSetKey: "bare", displays: [Self.studio, Self.dell],
                              spaces: [SpaceSnapshot(displayUUID: "AAAA-1111", position: 0, kind: .desktop, desktopNumber: 1)],
                              windows: [Self.window(Self.safari, display: "AAAA-1111", desktop: 1)])
        let error = try #require(Self.failure { try CLIScopeParser.parse(profile: profile, monitors: ["Dell"]) })
        #expect(error.exit == .usage)
    }

    // MARK: Output

    @Test func addingScopeAddsSummaryToObjectsOnly() {
        let object = CLIScopeParser.addingScope("Desktop 1 only", to: .object(["ok": .bool(true)]))
        #expect(object == .object(["ok": .bool(true), "scope": .string("Desktop 1 only")]))
        #expect(CLIScopeParser.addingScope("x", to: .int(3)) == .int(3))
    }

    @Test func optionsDeclareTheThreeRepeatableFlags() {
        #expect(CLIScopeParser.options.map(\.name) == ["monitor", "desktop", "app"])
        let allTakeValues = CLIScopeParser.options.allSatisfy { $0.takesValue }
        #expect(allTakeValues)
    }
}
