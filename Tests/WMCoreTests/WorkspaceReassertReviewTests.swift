import Foundation
import CoreGraphics
import Testing
@testable import WMCore

// Review findings 6 and 7 for WorkspaceModelStore.reassertActive.
@Suite struct WorkspaceReassertReviewTests {
    static let activeID = UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000A7")!
    static let otherID = UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000B7")!
    static let frame = CGRect(x: 100, y: 120, width: 800, height: 600)

    // Active workspace A owns window 1 (Xcode, pid 10). Workspace B claims Safari only by app.
    static func model(otherApps: [String] = ["com.apple.Safari"], activeApps: [String] = []) -> WorkspaceModel {
        WorkspaceModel(
            workspaces: [
                Workspace(id: activeID, name: "A", apps: activeApps,
                          windows: [WorkspaceWindowRef(windowID: 1, pid: 10)]),
                Workspace(id: otherID, name: "B", apps: otherApps),
            ],
            activeWorkspaceID: activeID,
            hiddenRecords: [])
    }

    // Finding 6: a showing window whose app is claimed only by another workspace's apps must be hidden.
    @Test func showingWindowOfOtherWorkspaceAppIsHidden() {
        let live = [
            VirtualLiveWindow(windowID: 1, pid: 10, frame: Self.frame, bundleID: "com.apple.dt.Xcode"),
            VirtualLiveWindow(windowID: 2, pid: 11, frame: Self.frame, bundleID: "com.apple.Safari"),
        ]
        let actions = WorkspaceModelStore.reassertActive(Self.model(), live: live)
        #expect(actions == [.hideWindow(windowID: 2, pid: 11)])
    }

    // Guard for finding 6: an app claimed by the active workspace's apps is not hidden by another workspace.
    @Test func appClaimedByActiveWorkspaceIsNotHidden() {
        let live = [
            VirtualLiveWindow(windowID: 1, pid: 10, frame: Self.frame, bundleID: "com.apple.dt.Xcode"),
            VirtualLiveWindow(windowID: 2, pid: 11, frame: Self.frame, bundleID: "com.apple.Safari"),
        ]
        let actions = WorkspaceModelStore.reassertActive(Self.model(activeApps: ["com.apple.Safari"]), live: live)
        #expect(actions.isEmpty)
    }

    // Finding 7: a window the user minimized is not hidden by the app, so no unhideApp for it.
    @Test func minimizedWindowOfActiveWorkspaceIsNotUnhidden() {
        let live = [
            VirtualLiveWindow(windowID: 1, pid: 10, frame: Self.frame, isOnScreen: false, isMinimized: true),
        ]
        #expect(WorkspaceModelStore.reassertActive(Self.model(), live: live).isEmpty)
    }

    // Guard for finding 7: a non-minimized off-screen window of the active workspace still means its app is hidden.
    @Test func hiddenAppWindowOfActiveWorkspaceIsUnhidden() {
        let live = [
            VirtualLiveWindow(windowID: 1, pid: 10, frame: Self.frame, isOnScreen: false),
        ]
        #expect(WorkspaceModelStore.reassertActive(Self.model(), live: live) == [.unhideApp(pid: 10)])
    }
}
