import Foundation
import Testing
@testable import WMCore

final class FakeWorkspaceSystem: WorkspaceSystem {
    struct Win { var pid: Int32; var frame: CGRect; var hiddenByApp = false }
    var windows: [UInt32: Win] = [:]
    var bundles: [Int32: String] = [:]
    var screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    var hideRefusedPIDs: Set<Int32> = []
    var parkRefused: Set<UInt32> = []
    var restoreIgnoresPosition: Set<UInt32> = []
    var calls: [String] = []
    var onCall: ((String) -> Void)?

    private func log(_ s: String) { calls.append(s); onCall?(s) }

    func liveWindows() -> [VirtualLiveWindow] {
        windows.map { id, w in
            let onScreen = !w.hiddenByApp && w.frame.minX < screens[0].maxX - 5 && w.frame.minY < screens[0].maxY - 5
            return VirtualLiveWindow(windowID: id, pid: w.pid, frame: w.frame, isOnScreen: onScreen)
        }.sorted { $0.windowID < $1.windowID }
    }
    func bundleID(ofPID pid: Int32) -> String? { bundles[pid] }
    func hideApp(pid: Int32) -> Bool {
        log("hideApp \(pid)")
        if hideRefusedPIDs.contains(pid) { return false }
        for id in windows.keys where windows[id]!.pid == pid { windows[id]!.hiddenByApp = true }
        return true
    }
    func unhideApp(pid: Int32) -> Bool {
        log("unhideApp \(pid)")
        for id in windows.keys where windows[id]!.pid == pid { windows[id]!.hiddenByApp = false }
        return true
    }
    func frame(ofWindow windowID: UInt32, pid: Int32) -> CGRect? { windows[windowID]?.frame }
    func setPosition(_ origin: CGPoint, ofWindow windowID: UInt32, pid: Int32) -> Bool {
        log("setPosition \(windowID)")
        if parkRefused.contains(windowID) && origin.x > 1000 { return false }
        if restoreIgnoresPosition.contains(windowID) && origin.x < 1000 { return true }
        windows[windowID]?.frame.origin = origin
        return true
    }
    func setFrame(_ frame: CGRect, ofWindow windowID: UInt32, pid: Int32) -> Bool {
        log("setFrame \(windowID)")
        windows[windowID]?.frame = frame
        return true
    }
    func screenFrames() -> [CGRect] { screens }
}

final class RecordingSaver: WorkspaceModelSaving {
    var saved: [WorkspaceModel] = []
    var failAfter: Int?
    struct Boom: Error {}
    func save(_ model: WorkspaceModel) throws {
        if let failAfter, saved.count >= failAfter { throw Boom() }
        saved.append(model)
    }
}

@Suite struct WorkspaceSwitcherTests {
    static let a = UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000A1")!
    static let b = UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000B1")!
    static func f(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 50, width: 600, height: 400) }

    /// A: window 1 (pid 10, whole app), windows 2 and 3 (pid 11, shared with an unassigned window 5).
    /// B: window 4 (pid 12).
    static func fixture() -> (WorkspaceModel, FakeWorkspaceSystem) {
        let sys = FakeWorkspaceSystem()
        sys.windows = [1: .init(pid: 10, frame: f(10)), 2: .init(pid: 11, frame: f(100)),
                       3: .init(pid: 11, frame: f(200)), 4: .init(pid: 12, frame: f(300)),
                       5: .init(pid: 11, frame: f(400))]
        sys.bundles = [10: "app.ten", 11: "app.eleven", 12: "app.twelve"]
        let model = WorkspaceModel(
            workspaces: [
                Workspace(id: a, name: "A", windows: [WorkspaceWindowRef(windowID: 1, pid: 10),
                                                      WorkspaceWindowRef(windowID: 2, pid: 11),
                                                      WorkspaceWindowRef(windowID: 3, pid: 11)]),
                Workspace(id: b, name: "B", windows: [WorkspaceWindowRef(windowID: 4, pid: 12)]),
            ], activeWorkspaceID: a)
        return (model, sys)
    }

    @Test func hidesWholeAppAndParksSharedAppWindows() throws {
        let (model, sys) = Self.fixture()
        let saver = RecordingSaver()
        let engine = WorkspaceSwitcher(model: model, system: sys, saver: saver)
        let result = try engine.switchTo(Self.b)

        #expect(result.hiddenApps == [10])
        #expect(Set(result.parkedWindows) == [2, 3])
        #expect(result.warnings.isEmpty)
        #expect(!sys.calls.contains("hideApp 11"))
        #expect(engine.model.activeWorkspaceID == Self.b)
        let records = Dictionary(uniqueKeysWithValues: engine.model.hiddenRecords.map { ($0.windowID, $0) })
        #expect(records[1]?.method == .appHidden)
        #expect(records[2]?.method == .parked)
        #expect(records[2]?.originalFrame == Self.f(100))
        #expect(records[2]?.workspaceID == Self.a)
        // window 5 (unassigned) and 4 (target) untouched
        #expect(sys.windows[5]?.frame == Self.f(400))
        #expect(sys.windows[4]?.frame == Self.f(300))
        #expect(sys.windows[2]?.frame.minX == 1439)
    }

    @Test func switchingBackRestoresEverything() throws {
        let (model, sys) = Self.fixture()
        let engine = WorkspaceSwitcher(model: model, system: sys, saver: RecordingSaver())
        try engine.switchTo(Self.b)
        let back = try engine.switchTo(Self.a)

        #expect(back.unhiddenApps == [10])
        #expect(sys.windows[2]?.frame == Self.f(100))
        #expect(sys.windows[3]?.frame == Self.f(200))
        #expect(sys.windows[1]?.hiddenByApp == false)
        #expect(back.hiddenApps == [12])
        #expect(Set(back.restoredWindows) == [1, 2, 3])
        #expect(engine.model.hiddenRecords.map(\.windowID) == [4])
        #expect(engine.model.activeWorkspaceID == Self.a)
    }

    @Test func savesBeforeEveryMoveAndNeverLeavesAWindowUnrecorded() throws {
        let (model, sys) = Self.fixture()
        let saver = RecordingSaver()
        sys.onCall = { call in
            // At the moment a window is moved or an app hidden, the latest saved model must already
            // hold a record for what is about to disappear.
            let last = saver.saved.last
            if call == "hideApp 10" { #expect(last?.hiddenRecords.contains { $0.windowID == 1 } == true) }
            if call == "setPosition 2" { #expect(last?.hiddenRecords.contains { $0.windowID == 2 } == true) }
            if call == "setPosition 3" { #expect(last?.hiddenRecords.contains { $0.windowID == 3 } == true) }
        }
        let engine = WorkspaceSwitcher(model: model, system: sys, saver: saver)
        let result = try engine.switchTo(Self.b)
        #expect(saver.saved.count == result.saveCount)
        #expect(saver.saved.last == engine.model)
    }

    @Test func crashMidSwitchIsRecoverable() throws {
        let (model, sys) = Self.fixture()
        let saver = RecordingSaver()
        var crashed: WorkspaceModel?
        sys.onCall = { call in if call == "setPosition 3" { crashed = saver.saved.last } }
        _ = try WorkspaceSwitcher(model: model, system: sys, saver: saver).switchTo(Self.b)
        let plan = WorkspaceModelStore.recover(try #require(crashed), live: sys.liveWindows())
        #expect(plan.actions.contains(.unhideApp(pid: 10)))
        #expect(plan.actions.contains { if case .restoreFrame(3, _, _) = $0 { return true } else { return false } })
    }

    @Test func appHideRefusedFallsBackToParking() throws {
        let (model, sys) = Self.fixture()
        sys.hideRefusedPIDs = [10]
        let engine = WorkspaceSwitcher(model: model, system: sys, saver: RecordingSaver())
        let result = try engine.switchTo(Self.b)
        #expect(result.hiddenApps.isEmpty)
        #expect(result.parkedWindows.contains(1))
        #expect(result.warnings.count == 1)
        #expect(engine.model.hiddenRecords.first { $0.windowID == 1 }?.method == .parked)
    }

    @Test func parkRefusedLeavesNoRecord() throws {
        let (model, sys) = Self.fixture()
        sys.parkRefused = [2]
        let engine = WorkspaceSwitcher(model: model, system: sys, saver: RecordingSaver())
        let result = try engine.switchTo(Self.b)
        #expect(!engine.model.hiddenRecords.contains { $0.windowID == 2 })
        #expect(result.parkedWindows.contains(3))
        #expect(result.hasWarnings)
    }

    @Test func strongRestoreUsedWhenPositionAloneFails() throws {
        let (model, sys) = Self.fixture()
        let engine = WorkspaceSwitcher(model: model, system: sys, saver: RecordingSaver())
        try engine.switchTo(Self.b)
        sys.restoreIgnoresPosition = [2]
        let back = try engine.switchTo(Self.a)
        #expect(sys.calls.contains("setFrame 2"))
        #expect(sys.windows[2]?.frame == Self.f(100))
        #expect(back.warnings.isEmpty)
    }

    @Test func goneWindowsAreReportedAndDropped() throws {
        let (model, sys) = Self.fixture()
        let engine = WorkspaceSwitcher(model: model, system: sys, saver: RecordingSaver())
        try engine.switchTo(Self.b)
        sys.windows[3] = nil
        let back = try engine.switchTo(Self.a)
        #expect(back.missingWindows == [3])
        #expect(!engine.model.hiddenRecords.contains { $0.windowID == 3 })
        #expect(back.hasWarnings)
    }

    @Test func sameWorkspaceIsNoOpAndUnknownThrows() throws {
        let (model, sys) = Self.fixture()
        let engine = WorkspaceSwitcher(model: model, system: sys, saver: RecordingSaver())
        #expect(try engine.switchTo(Self.a).wasNoOp)
        #expect(sys.calls.isEmpty)
        let unknown = UUID()
        #expect(throws: WorkspaceSwitchError.unknownWorkspace(unknown)) { try engine.switchTo(unknown) }
    }

    @Test func saveFailureBeforeMovingThrowsAndTouchesNothing() throws {
        let (model, sys) = Self.fixture()
        let saver = RecordingSaver()
        saver.failAfter = 0
        let engine = WorkspaceSwitcher(model: model, system: sys, saver: saver)
        #expect(throws: (any Error).self) { try engine.switchTo(Self.b) }
        #expect(sys.calls.isEmpty)
        #expect(sys.windows[2]?.frame == Self.f(100))
    }

    @Test func timingsComeFromTheClock() throws {
        let (model, sys) = Self.fixture()
        var t: TimeInterval = 0
        let engine = WorkspaceSwitcher(model: model, system: sys, saver: RecordingSaver(),
                                       clock: { t += 1; return t })
        let result = try engine.switchTo(Self.b)
        #expect(result.totalSeconds > 0)
        #expect(result.hideSeconds > 0 && result.showSeconds > 0)
    }

    @Test func appSharedWithTargetIsNotAppHidden() throws {
        let (model, sys) = Self.fixture()
        var m = model
        m.workspaces[1].windows.append(WorkspaceWindowRef(windowID: 5, pid: 11))
        let engine = WorkspaceSwitcher(model: m, system: sys, saver: RecordingSaver())
        let result = try engine.switchTo(Self.b)
        #expect(!result.hiddenApps.contains(11))
        #expect(Set(result.parkedWindows) == [2, 3])
    }

    @Test func wholeAppBundleInOldWorkspaceIsHiddenAndShownByBundle() throws {
        let (model, sys) = Self.fixture()
        var m = model
        m.workspaces[0].apps = ["app.eleven"]  // all of pid 11 incl. unassigned window 5
        let engine = WorkspaceSwitcher(model: m, system: sys, saver: RecordingSaver())
        let result = try engine.switchTo(Self.b)
        #expect(Set(result.hiddenApps) == [10, 11])
        let back = try engine.switchTo(Self.a)
        #expect(back.unhiddenApps.contains(11))
        #expect(sys.windows[5]?.hiddenByApp == false)
    }
}
