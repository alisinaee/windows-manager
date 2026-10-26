import Foundation
import Testing
@testable import WMCore

/// Hides windows of hidden apps from the list, like a window server that omits them.
private struct OmitsHiddenAppWindows: WorkspaceSystem {
    let base: FakeWorkspaceSystem
    func liveWindows() -> [VirtualLiveWindow] {
        base.liveWindows().filter { base.windows[$0.windowID]?.hiddenByApp == false }
    }
    func bundleID(ofPID pid: Int32) -> String? { base.bundleID(ofPID: pid) }
    func hideApp(pid: Int32) -> Bool { base.hideApp(pid: pid) }
    func unhideApp(pid: Int32) -> Bool { base.unhideApp(pid: pid) }
    func frame(ofWindow windowID: UInt32, pid: Int32) -> CGRect? { base.frame(ofWindow: windowID, pid: pid) }
    func setPosition(_ origin: CGPoint, ofWindow windowID: UInt32, pid: Int32) -> Bool {
        base.setPosition(origin, ofWindow: windowID, pid: pid)
    }
    func setFrame(_ frame: CGRect, ofWindow windowID: UInt32, pid: Int32) -> Bool {
        base.setFrame(frame, ofWindow: windowID, pid: pid)
    }
    func screenFrames() -> [CGRect] { base.screenFrames() }
}

private struct FixedInfo: MixedModeSpaceInfo {
    var snap: MixedModeSnapshot
    func snapshot(forWindows windowIDs: [UInt32]) -> MixedModeSnapshot { snap }
}

@Suite struct WorkspaceSwitcherReviewTests {
    static let a = WorkspaceSwitcherTests.a
    static let b = WorkspaceSwitcherTests.b
    static let c = UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000C1")!
    static func f(_ x: CGFloat) -> CGRect { WorkspaceSwitcherTests.f(x) }

    // Finding 1: a parked window of workspace C shares pid 10 with window 1 of A.
    @Test func parkedWindowOfSamePidIsNotStrandedUnderHiddenApp() throws {
        let sys = FakeWorkspaceSystem()
        sys.windows = [1: .init(pid: 10, frame: Self.f(10)),
                       2: .init(pid: 10, frame: CGRect(x: 1439, y: 50, width: 600, height: 400)),
                       3: .init(pid: 20, frame: Self.f(300))]
        sys.bundles = [10: "app.ten", 20: "app.twenty"]
        var model = WorkspaceModel(workspaces: [
            Workspace(id: Self.a, name: "A", windows: [WorkspaceWindowRef(windowID: 1, pid: 10)]),
            Workspace(id: Self.b, name: "B", windows: [WorkspaceWindowRef(windowID: 3, pid: 20)]),
            Workspace(id: Self.c, name: "C", windows: [WorkspaceWindowRef(windowID: 2, pid: 10)]),
        ], activeWorkspaceID: Self.a)
        model.recordHidden(HiddenWindowRecord(windowID: 2, pid: 10, bundleID: "app.ten", method: .parked,
                                              originalFrame: Self.f(100), workspaceID: Self.c))
        let engine = WorkspaceSwitcher(model: model, system: sys, saver: RecordingSaver())
        try engine.switchTo(Self.b)
        #expect(!sys.calls.contains("hideApp 10"))
        try engine.switchTo(Self.c)
        #expect(sys.windows[2]?.hiddenByApp == false)
        #expect(sys.windows[2]?.frame == Self.f(100))
        #expect(sys.liveWindows().first { $0.windowID == 2 }?.isOnScreen == true)
    }

    // Finding 2: the window is on another native Space, so the filtered source does not list it.
    @Test func windowOnAnotherSpaceKeepsItsRecord() throws {
        let (model, sys) = WorkspaceSwitcherTests.fixture()
        let first = WorkspaceSwitcher(model: model, system: sys, saver: RecordingSaver())
        try first.switchTo(Self.b)
        let snap = MixedModeSnapshot(visibleSpaceIDs: [1], windowSpaceIDs: [2: [2]], activeSpaceID: 1)
        let aware = FullScreenAwareSystem(base: sys, info: FixedInfo(snap: snap))
        let engine = WorkspaceSwitcher(model: first.model, system: aware, saver: RecordingSaver())
        let back = try engine.switchTo(Self.a)
        #expect(engine.model.hiddenRecords.contains { $0.windowID == 2 && $0.method == .parked })
        #expect(!back.missingWindows.contains(2))
        #expect(back.hasWarnings)
        #expect(sys.windows[2]?.frame.minX == 1439)
        #expect(sys.windows[3]?.frame == Self.f(200))
    }

    @Test func trulyClosedWindowStillDropsWithFilterActive() throws {
        let (model, sys) = WorkspaceSwitcherTests.fixture()
        let first = WorkspaceSwitcher(model: model, system: sys, saver: RecordingSaver())
        try first.switchTo(Self.b)
        sys.windows[3] = nil
        let snap = MixedModeSnapshot(visibleSpaceIDs: [1], windowSpaceIDs: [2: [2]], activeSpaceID: 1)
        let engine = WorkspaceSwitcher(model: first.model, system: FullScreenAwareSystem(base: sys, info: FixedInfo(snap: snap)),
                                       saver: RecordingSaver())
        let back = try engine.switchTo(Self.a)
        #expect(back.missingWindows == [3])
        #expect(!engine.model.hiddenRecords.contains { $0.windowID == 3 })
        #expect(engine.model.hiddenRecords.contains { $0.windowID == 2 })
    }

    // Finding 3: window 2 belongs to C by app; unhiding pid 10 for A must not drop its record.
    @Test func unhidingPidKeepsAndReparksOtherWorkspacesWindows() throws {
        let sys = FakeWorkspaceSystem()
        sys.windows = [1: .init(pid: 10, frame: Self.f(10), hiddenByApp: true),
                       2: .init(pid: 10, frame: Self.f(100), hiddenByApp: true),
                       3: .init(pid: 20, frame: Self.f(300))]
        sys.bundles = [10: "app.ten", 20: "app.twenty"]
        var model = WorkspaceModel(workspaces: [
            Workspace(id: Self.a, name: "A", windows: [WorkspaceWindowRef(windowID: 1, pid: 10)]),
            Workspace(id: Self.b, name: "B", windows: [WorkspaceWindowRef(windowID: 3, pid: 20)]),
            Workspace(id: Self.c, name: "C", apps: ["app.ten"]),
        ], activeWorkspaceID: Self.b)
        model.recordHidden(HiddenWindowRecord(windowID: 1, pid: 10, bundleID: nil, method: .appHidden,
                                              originalFrame: Self.f(10), workspaceID: Self.a))
        model.recordHidden(HiddenWindowRecord(windowID: 2, pid: 10, bundleID: "app.ten", method: .appHidden,
                                              originalFrame: Self.f(100), workspaceID: Self.c))
        let engine = WorkspaceSwitcher(model: model, system: sys, saver: RecordingSaver())
        _ = try engine.switchTo(Self.a)
        let r2 = try #require(engine.model.hiddenRecords.first { $0.windowID == 2 })
        #expect(r2.method == .parked)
        #expect(r2.workspaceID == Self.c)
        #expect(r2.originalFrame == Self.f(100))
        #expect(sys.windows[2]?.frame.minX == 1439)
        #expect(!engine.model.hiddenRecords.contains { $0.windowID == 1 })
        #expect(sys.windows[1]?.hiddenByApp == false)
    }

    // Finding 10: windows of a hidden app are missing from the list until the app is unhidden.
    @Test func showRefreshesLiveWindowsAfterUnhide() throws {
        let (model, base) = WorkspaceSwitcherTests.fixture()
        let sys = OmitsHiddenAppWindows(base: base)
        let engine = WorkspaceSwitcher(model: model, system: sys, saver: RecordingSaver())
        try engine.switchTo(Self.b)
        let back = try engine.switchTo(Self.a)
        #expect(back.missingWindows.isEmpty)
        #expect(back.restoredWindows.contains(1))
        #expect(back.warnings.isEmpty)
    }
}
