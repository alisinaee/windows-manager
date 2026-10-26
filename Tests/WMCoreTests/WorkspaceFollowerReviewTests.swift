import Foundation
import Testing
@testable import WMCore

// Review finding 5: a specific window assignment in another workspace must beat an app-wide
// claim by the active workspace.
struct WorkspaceFollowerReviewTests {
    final class Clock { var t: TimeInterval = 100 }

    let activeID = UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000F1")!
    let otherID = UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000F2")!

    func model() -> WorkspaceModel {
        let active = Workspace(id: activeID, name: "A", apps: ["com.google.Chrome"])
        let other = Workspace(id: otherID, name: "B", windows: [WorkspaceWindowRef(windowID: 42, pid: 10, bundleID: "com.google.Chrome")])
        return WorkspaceModel(workspaces: [active, other], activeWorkspaceID: activeID)
    }

    @Test func windowAssignmentInOtherWorkspaceBeatsActiveAppClaim() {
        let clock = Clock()
        let f = WorkspaceFollower(clock: { clock.t })
        let event = WorkspaceActivationEvent(bundleID: "com.google.Chrome", windowID: 42)
        #expect(f.targetWorkspace(for: event, model: model()) == otherID)
    }

    @Test func activeWindowAssignmentStillWins() {
        let clock = Clock()
        let f = WorkspaceFollower(clock: { clock.t })
        var m = model()
        m.workspaces[0].windows = [WorkspaceWindowRef(windowID: 7, pid: 10)]
        m.workspaces[1].windows = [WorkspaceWindowRef(windowID: 42, pid: 10)]
        let event = WorkspaceActivationEvent(bundleID: "com.google.Chrome", windowID: 7)
        #expect(f.targetWorkspace(for: event, model: m) == nil)
    }
}
