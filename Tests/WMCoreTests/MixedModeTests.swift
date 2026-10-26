import Foundation
import Testing
@testable import WMCore

private struct FakeSource: WorkspaceWindowSource {
    var windows: [VirtualLiveWindow]
    func liveWindows() -> [VirtualLiveWindow] { windows }
    func bundleID(ofPID pid: Int32) -> String? { "app.\(pid)" }
}

private struct FakeInfo: MixedModeSpaceInfo {
    var snap: MixedModeSnapshot
    func snapshot(forWindows windowIDs: [UInt32]) -> MixedModeSnapshot { snap }
}

private func win(_ id: UInt32, pid: Int32 = 1) -> VirtualLiveWindow {
    VirtualLiveWindow(windowID: id, pid: pid, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
}

struct MixedModeTests {
    // Spaces: 1 = desktop (visible), 2 = desktop (other), 9 = full-screen.
    private let snap = MixedModeSnapshot(
        visibleSpaceIDs: [1], fullScreenSpaceIDs: [9],
        windowSpaceIDs: [10: [1], 11: [9], 12: [2], 13: [1, 2], 14: [], 15: [1]],
        fullScreenWindowIDs: [15], activeSpaceID: 1)

    @Test func filterDropsFullScreenAndOtherSpaceWindows() {
        let all = [10, 11, 12, 13, 14, 15, 99].map { win(UInt32($0)) }
        let kept = MixedModeFilter.filter(all, snapshot: snap).map(\.windowID)
        // 11 full-screen Space, 12 other Space, 15 flagged full-screen. 14 and 99 are unknown: kept.
        #expect(kept == [10, 13, 14, 99])
    }

    @Test func decoratorFiltersLiveWindowsAndForwardsBundleID() {
        let src = FakeSource(windows: [10, 11, 12].map { win(UInt32($0), pid: 7) })
        let deco = FullScreenAwareWindowSource(base: src, info: FakeInfo(snap: snap))
        #expect(deco.liveWindows().map(\.windowID) == [10])
        #expect(deco.bundleID(ofPID: 7) == "app.7")
    }

    @Test func emptySnapshotKeepsEverything() {
        let all = [win(1), win(2)]
        #expect(MixedModeFilter.filter(all, snapshot: MixedModeSnapshot()).count == 2)
    }

    @Test func activeSpaceFullScreenFlag() {
        var s = snap
        #expect(!s.activeSpaceIsFullScreen)
        s.activeSpaceID = 9
        #expect(s.activeSpaceIsFullScreen)
        s.activeSpaceID = nil
        #expect(!s.activeSpaceIsFullScreen)
    }

    @Test func switchAppliesNowOnNormalDesktop() {
        var d = DeferredSwitch()
        let a = UUID()
        #expect(d.request(a, activeSpaceIsFullScreen: false) == a)
        #expect(!d.hasPending)
    }

    @Test func switchDefersOnFullScreenAndLatestWins() {
        var d = DeferredSwitch()
        let a = UUID(), b = UUID()
        #expect(d.request(a, activeSpaceIsFullScreen: true) == nil)
        #expect(d.request(b, activeSpaceIsFullScreen: true) == nil)
        #expect(d.pending == b)
        // Still full screen: nothing to apply.
        #expect(d.activeSpaceChanged(activeSpaceIsFullScreen: true, appliedWorkspace: nil) == nil)
        #expect(d.pending == b)
        // Back on a desktop: apply once.
        #expect(d.activeSpaceChanged(activeSpaceIsFullScreen: false, appliedWorkspace: a) == b)
        #expect(!d.hasPending)
        #expect(d.activeSpaceChanged(activeSpaceIsFullScreen: false, appliedWorkspace: a) == nil)
    }

    @Test func pendingMatchingAppliedWorkspaceIsDropped() {
        var d = DeferredSwitch()
        let a = UUID()
        _ = d.request(a, activeSpaceIsFullScreen: true)
        #expect(d.activeSpaceChanged(activeSpaceIsFullScreen: false, appliedWorkspace: a) == nil)
        #expect(!d.hasPending)
    }

    @Test func immediateRequestClearsOlderPending() {
        var d = DeferredSwitch()
        let a = UUID(), b = UUID()
        _ = d.request(a, activeSpaceIsFullScreen: true)
        #expect(d.request(b, activeSpaceIsFullScreen: false) == b)
        #expect(!d.hasPending)
    }

    @Test func cancelClearsPending() {
        var d = DeferredSwitch(pending: UUID())
        d.cancel()
        #expect(!d.hasPending)
    }
}
