import CoreGraphics
import Foundation
import Testing
@testable import WMCore

private let dispA = DisplayIdentity(uuid: "A", name: "Studio", frame: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 2000, height: 1000), isMain: true, isBuiltIn: false)
private let dispB = DisplayIdentity(uuid: "B", name: "Dell", frame: CGRect(x: 2000, y: 0, width: 1000, height: 1000),
                                    visibleFrame: CGRect(x: 2000, y: 0, width: 1000, height: 1000), isMain: false, isBuiltIn: false)
private let safari = AppRef(bundleID: "com.apple.Safari", name: "Safari")
private let mail = AppRef(bundleID: "com.apple.mail", name: "Mail")
private let xcode = AppRef(bundleID: "com.apple.dt.Xcode", name: "Xcode")

private func win(_ app: AppRef, _ display: String, _ placement: SpacePlacement, minimized: Bool = false,
                 fullScreen: Bool = false) -> WindowSnapshot {
    WindowSnapshot(app: app, displayUUID: display, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                   relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), placement: placement,
                   isFullScreen: fullScreen, isMinimized: minimized)
}

/// A: Desktop 1 (safari, mail), Desktop 2 (empty), full-screen Space (xcode), plus a minimized mail window. B: Desktop 1 (safari).
private struct Fixture {
    let w1 = win(safari, "A", .desktop(number: 1))
    let w2 = win(mail, "A", .desktop(number: 1))
    let wFull: WindowSnapshot
    let wMin = win(mail, "A", .desktop(number: 1), minimized: true)
    let w3 = win(safari, "B", .desktop(number: 1))
    let profile: Profile

    init() {
        wFull = win(xcode, "A", .fullScreen(position: 2), fullScreen: true)
        let spaces = [
            SpaceSnapshot(displayUUID: "A", position: 0, kind: .desktop, desktopNumber: 1),
            SpaceSnapshot(displayUUID: "A", position: 1, kind: .desktop, desktopNumber: 2),
            SpaceSnapshot(displayUUID: "A", position: 2, kind: .fullScreen, fullScreenWindowIDs: [wFull.id]),
            SpaceSnapshot(displayUUID: "B", position: 0, kind: .desktop, desktopNumber: 1),
        ]
        profile = Profile(name: "P", monitorSetKey: "k", displays: [dispA, dispB], spaces: spaces,
                          windows: [w1, w2, wFull, wMin, w3])
    }
}

@Suite struct CaptureSelectionTests {
    @Test func treeGroupsWindowsUnderMonitorsAndSpaces() {
        let f = Fixture()
        let tree = CaptureSelectionTree(profile: f.profile)
        #expect(tree.monitors.map(\.displayUUID) == ["A", "B"])
        let a = tree.monitors[0].groups
        #expect(a.map(\.id) == ["A#0", "A#1", "A#2", "A#other"])
        #expect(a[0].windowIDs == [f.w1.id, f.w2.id])
        #expect(a[1].windowIDs.isEmpty)
        #expect(a[2].windowIDs == [f.wFull.id])
        #expect(a[3].windowIDs == [f.wMin.id])
        #expect(tree.allWindowIDs.count == 5)
    }

    @Test func startsFullySelectedAndRoundTripsUnchanged() {
        let f = Fixture()
        let sel = CaptureSelection(tree: CaptureSelectionTree(profile: f.profile))
        #expect(sel.selectedWindows == 5 && sel.totalWindows == 5 && sel.hasSelection)
        #expect(sel.applying(to: f.profile) == f.profile)
    }

    @Test func uncheckingAWindowDropsItAndKeepsTheRest() {
        let f = Fixture()
        var sel = CaptureSelection(tree: CaptureSelectionTree(profile: f.profile))
        sel.toggle(window: f.w2.id)
        let p = sel.applying(to: f.profile)
        #expect(p.windows.count == 4 && !p.windows.contains { $0.id == f.w2.id })
        #expect(p.spaces.count == 4)
        #expect(sel.state(of: sel.tree.monitors[0].groups[0]) == .mixed)
        #expect(sel.state(of: sel.tree.monitors[0]) == .mixed)
        #expect(p.validate().isEmpty)
    }

    @Test func uncheckingAllWindowsOfADesktopDropsIt() {
        let f = Fixture()
        var sel = CaptureSelection(tree: CaptureSelectionTree(profile: f.profile))
        sel.toggle(group: sel.tree.monitors[0].groups[0])
        #expect(sel.state(of: sel.tree.monitors[0].groups[0]) == .off)
        let p = sel.applying(to: f.profile)
        // Desktop 1 of A is gone; Desktop 2 (empty, still ticked) and the full-screen Space move up.
        #expect(p.spaces(onDisplay: "A").map(\.desktopNumber) == [2, nil])
        #expect(p.spaces(onDisplay: "A").map(\.position) == [0, 1])
        #expect(p.validate().isEmpty)
    }

    @Test func emptyDesktopIsKeptOnlyWhileTicked() {
        let f = Fixture()
        var sel = CaptureSelection(tree: CaptureSelectionTree(profile: f.profile))
        let empty = sel.tree.monitors[0].groups[1]
        #expect(sel.state(of: empty) == .on)
        sel.toggle(group: empty)
        #expect(sel.state(of: empty) == .off)
        #expect(!sel.applying(to: f.profile).spaces.contains { $0.displayUUID == "A" && $0.desktopNumber == 2 })
    }

    @Test func uncheckingAMonitorDropsItAndItsSpaces() {
        let f = Fixture()
        var sel = CaptureSelection(tree: CaptureSelectionTree(profile: f.profile))
        sel.toggle(monitor: sel.tree.monitors[1])
        let p = sel.applying(to: f.profile)
        #expect(p.displays.map(\.uuid) == ["A"])
        #expect(p.windows.allSatisfy { $0.displayUUID == "A" })
        #expect(p.spaces.allSatisfy { $0.displayUUID == "A" })
        #expect(p.validate().isEmpty)
        sel.toggle(monitor: sel.tree.monitors[1])
        #expect(sel.state(of: sel.tree.monitors[1]) == .on)
    }

    @Test func fullScreenSpaceGoesWithItsWindow() {
        let f = Fixture()
        var sel = CaptureSelection(tree: CaptureSelectionTree(profile: f.profile))
        sel.toggle(window: f.wFull.id)
        let p = sel.applying(to: f.profile)
        #expect(!p.spaces.contains { $0.kind == .fullScreen })
        #expect(p.validate().isEmpty)
    }

    @Test func selectNoneAndAll() {
        let f = Fixture()
        var sel = CaptureSelection(tree: CaptureSelectionTree(profile: f.profile))
        sel.selectNone()
        #expect(!sel.hasSelection && sel.selectedWindows == 0)
        let p = sel.applying(to: f.profile)
        #expect(p.windows.isEmpty && p.spaces.isEmpty && p.displays.isEmpty)
        sel.selectAll()
        #expect(sel.applying(to: f.profile) == f.profile)
    }

    @Test func appListFollowsRemainingWindowsAndLaunchPlan() {
        let f = Fixture()
        var profile = f.profile
        profile.launchPlan = LaunchPlan(mode: .sequential, items: [LaunchItem(app: xcode), LaunchItem(app: safari),
                                                                    LaunchItem(app: AppRef(bundleID: "x.y", name: "Helper"), withoutWindows: true)])
        var sel = CaptureSelection(tree: CaptureSelectionTree(profile: profile))
        sel.toggle(window: f.wFull.id)
        let p = sel.applying(to: profile)
        #expect(!p.apps.contains { $0.name == "Xcode" })
        #expect(p.launchPlan?.items.map(\.app.name) == ["Safari", "Helper"])
    }

    @Test func allDesktopsWindowSitsInOtherGroupOnly() {
        let f = Fixture()
        let all = win(mail, "A", .allDesktops)
        var profile = f.profile
        profile.windows.append(all)
        let tree = CaptureSelectionTree(profile: profile)
        #expect(tree.allWindowIDs.filter { $0 == all.id }.count == 1)
        #expect(tree.monitors[0].groups.last?.windowIDs.contains(all.id) == true)
    }
}
