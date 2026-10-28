import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite struct RestoreScopeTests {
    static let a = "UUID-A"
    static let b = "UUID-B"
    static let rect = CGRect(x: 0, y: 0, width: 100, height: 100)

    static func display(_ uuid: String, _ name: String) -> DisplayIdentity {
        DisplayIdentity(uuid: uuid, name: name, frame: rect, visibleFrame: rect, isMain: uuid == a, isBuiltIn: false)
    }

    static func window(_ bundle: String, _ display: String, _ placement: SpacePlacement) -> WindowSnapshot {
        WindowSnapshot(app: AppRef(bundleID: bundle, name: bundle), displayUUID: display, frame: rect,
                       relativeFrame: rect, placement: placement)
    }

    /// A: desktops 1, 2, 3 (3 is empty). B: desktop 1 and a full-screen Space.
    static func profile() -> Profile {
        let full = window("com.fs", b, .fullScreen(position: 1))
        let windows = [
            window("com.mail", a, .desktop(number: 1)),
            window("com.safari", a, .desktop(number: 2)),
            window("com.mail", a, .desktop(number: 2)),
            window("com.music", a, .allDesktops),
            window("com.mail", b, .desktop(number: 1)),
            window("com.music", b, .allDesktops),
            full,
        ]
        let spaces = [
            SpaceSnapshot(displayUUID: a, position: 0, kind: .desktop, desktopNumber: 1),
            SpaceSnapshot(displayUUID: a, position: 1, kind: .desktop, desktopNumber: 2),
            SpaceSnapshot(displayUUID: a, position: 2, kind: .desktop, desktopNumber: 3),
            SpaceSnapshot(displayUUID: b, position: 0, kind: .desktop, desktopNumber: 1),
            SpaceSnapshot(displayUUID: b, position: 1, kind: .fullScreen, fullScreenWindowIDs: [full.id]),
        ]
        return Profile(name: "P", monitorSetKey: "k", displays: [display(a, "DELL"), display(b, "LG")],
                       spaces: spaces, windows: windows)
    }

    @Test func wholeReturnsIdenticalProfile() {
        let p = Self.profile()
        #expect(RestoreScope.whole.isWhole)
        #expect(RestoreScope.whole.filter(p) == p)
        #expect(!RestoreScope.whole.isEmpty(for: p))
        #expect(RestoreScope.whole.describe(profile: p) == "Whole profile")
    }

    @Test func filterByMonitor() {
        let p = Self.profile()
        let r = RestoreScope(displays: [Self.b]).filter(p)
        #expect(Set(r.windows.map(\.displayUUID)) == [Self.b])
        #expect(r.windows.count == 3)
        #expect(r.displays.map(\.uuid) == [Self.b])
        #expect(r.spaces.count == 2)
    }

    @Test func filterByDesktopKeepsAllDesktopsWindowsAndDoesNotRenumber() {
        let p = Self.profile()
        let scope = RestoreScope(desktops: [SpaceRef(displayUUID: Self.a, desktopNumber: 2)])
        let r = scope.filter(p)
        #expect(r.windows.count == 3)  // safari, mail on desktop 2, music allDesktops
        #expect(r.windows.allSatisfy { $0.displayUUID == Self.a })
        #expect(r.windows.contains { $0.placement == .allDesktops })
        #expect(r.windows.filter { $0.placement == .desktop(number: 2) }.count == 2)
        #expect(r.spaces.count == 1)
        #expect(r.spaces[0].desktopNumber == 2)
        #expect(r.spaces[0].position == 1)
        #expect(r.displays.map(\.uuid) == [Self.a])
        #expect(scope.describe(profile: p) == "Desktop 2 on DELL only")
    }

    @Test func filterByApp() {
        let p = Self.profile()
        let r = RestoreScope(apps: ["COM.MAIL"]).filter(p)
        #expect(r.windows.count == 3)
        #expect(r.windows.allSatisfy { $0.app.bundleID == "com.mail" })
        #expect(r.spaces.filter { $0.kind == .desktop }.count == 4)
        #expect(r.spaces.allSatisfy { $0.kind != .fullScreen })
    }

    @Test func combinedScope() {
        let p = Self.profile()
        let scope = RestoreScope(displays: [Self.a], desktops: [SpaceRef(displayUUID: Self.a, desktopNumber: 2)],
                                 apps: ["com.mail", "com.music"])
        let r = scope.filter(p)
        #expect(r.windows.count == 2)  // mail on desktop 2, music allDesktops
        #expect(Set(r.windows.map { $0.app.bundleID ?? "" }) == ["com.mail", "com.music"])
        #expect(r.spaces.count == 1)
    }

    @Test func fullScreenWithoutDesktopScope() {
        let p = Self.profile()
        let r = RestoreScope(displays: [Self.b], apps: ["com.fs"]).filter(p)
        #expect(r.windows.count == 1)
        #expect(r.spaces.contains { $0.kind == .fullScreen })
    }

    @Test func matchesHelper() {
        let scope = RestoreScope(desktops: [SpaceRef(displayUUID: Self.a, desktopNumber: 2)])
        #expect(scope.matches(display: Self.a, desktop: 2, bundleID: "x"))
        #expect(scope.matches(display: Self.a, desktop: nil, bundleID: "x"))
        #expect(!scope.matches(display: Self.a, desktop: 1, bundleID: "x"))
        #expect(!scope.matches(display: Self.b, desktop: 2, bundleID: "x"))
    }

    @Test func emptyScopeDetection() {
        let p = Self.profile()
        #expect(RestoreScope(displays: ["missing"]).isEmpty(for: p))
        #expect(RestoreScope(desktops: [SpaceRef(displayUUID: Self.a, desktopNumber: 9)]).isEmpty(for: p))
        #expect(RestoreScope(apps: ["com.none"]).isEmpty(for: p))
        #expect(RestoreScope(displays: []).isEmpty(for: p))
        #expect(!RestoreScope(apps: ["com.mail"]).isEmpty(for: p))
        // An empty Desktop still counts as something in scope.
        #expect(!RestoreScope(desktops: [SpaceRef(displayUUID: Self.a, desktopNumber: 3)]).isEmpty(for: p))
        #expect(ScopeError.emptyScope == .emptyScope)
    }

    @Test func codableRoundTrip() throws {
        let scope = RestoreScope(displays: [Self.a], desktops: [SpaceRef(displayUUID: Self.a, desktopNumber: 2)],
                                 apps: ["com.mail"])
        let data = try JSONEncoder().encode(scope)
        #expect(try JSONDecoder().decode(RestoreScope.self, from: data) == scope)
        let whole = try JSONEncoder().encode(RestoreScope.whole)
        #expect(try JSONDecoder().decode(RestoreScope.self, from: whole) == .whole)
    }
}
