import Foundation
import Testing
@testable import WMCore

struct WorkspaceFollowerTests {
    let a = Workspace(name: "A", apps: ["com.a"], windows: [WorkspaceWindowRef(windowID: 10, pid: 1)])
    let b = Workspace(name: "B", apps: ["com.b"], windows: [WorkspaceWindowRef(windowID: 20, pid: 2)])
    let c = Workspace(name: "C", apps: ["com.c"])

    func model(active: Int? = 0) -> WorkspaceModel {
        let all = [a, b, c]
        return WorkspaceModel(workspaces: all, activeWorkspaceID: active.map { all[$0].id })
    }

    final class Clock { var t: TimeInterval = 100 }

    func follower(_ clock: Clock) -> WorkspaceFollower { WorkspaceFollower(clock: { clock.t }) }

    @Test func appOfOtherWorkspaceSwitches() {
        let clock = Clock()
        #expect(follower(clock).targetWorkspace(for: .init(bundleID: "com.b"), model: model()) == b.id)
    }

    @Test func currentOrUnassignedDoesNothing() {
        let clock = Clock()
        let f = follower(clock)
        #expect(f.targetWorkspace(for: .init(bundleID: "com.a"), model: model()) == nil)
        #expect(f.targetWorkspace(for: .init(bundleID: "com.none"), model: model()) == nil)
        #expect(f.targetWorkspace(for: .init(bundleID: nil), model: model()) == nil)
    }

    @Test func windowAssignmentBeatsOtherAppAssignment() {
        let clock = Clock()
        // Window 20 belongs to B, though its app com.a is assigned to A (the active one is C).
        let e = WorkspaceActivationEvent(bundleID: "com.a", windowID: 20)
        #expect(follower(clock).targetWorkspace(for: e, model: model(active: 2)) == b.id)
    }

    @Test func activeWorkspaceClaimWins() {
        let clock = Clock()
        let e = WorkspaceActivationEvent(bundleID: "com.b", windowID: 10)
        #expect(follower(clock).targetWorkspace(for: e, model: model(active: 0)) == nil)
    }

    @Test func debounceIgnoresRapidEvents() {
        let clock = Clock()
        let f = follower(clock)
        #expect(f.targetWorkspace(for: .init(bundleID: "com.b"), model: model()) == b.id)
        clock.t += 0.1
        #expect(f.targetWorkspace(for: .init(bundleID: "com.c"), model: model()) == nil)
        clock.t += 0.3
        #expect(f.targetWorkspace(for: .init(bundleID: "com.c"), model: model()) == c.id)
    }

    @Test func isSwitchingAndSettleIgnoreOwnEvents() {
        let clock = Clock()
        let f = follower(clock)
        f.isSwitching = true
        #expect(f.targetWorkspace(for: .init(bundleID: "com.b"), model: model()) == nil)
        f.switchDidEnd()
        clock.t += 0.2
        #expect(f.targetWorkspace(for: .init(bundleID: "com.b"), model: model()) == nil)
        clock.t += 0.5
        #expect(f.targetWorkspace(for: .init(bundleID: "com.b"), model: model()) == b.id)
    }

    @Test func disabledDoesNothing() {
        let clock = Clock()
        let f = follower(clock)
        f.isEnabled = false
        #expect(f.targetWorkspace(for: .init(bundleID: "com.b"), model: model()) == nil)
    }

    @Test func commandsWrapAround() {
        #expect(WorkspaceSwitchCommand.index(2).target(in: model()) == b.id)
        #expect(WorkspaceSwitchCommand.index(0).target(in: model()) == nil)
        #expect(WorkspaceSwitchCommand.index(4).target(in: model()) == nil)
        #expect(WorkspaceSwitchCommand.next.target(in: model(active: 0)) == b.id)
        #expect(WorkspaceSwitchCommand.next.target(in: model(active: 2)) == a.id)
        #expect(WorkspaceSwitchCommand.previous.target(in: model(active: 0)) == c.id)
        #expect(WorkspaceSwitchCommand.previous.target(in: model(active: 2)) == b.id)
    }

    @Test func commandsWithoutActiveOrWorkspaces() {
        #expect(WorkspaceSwitchCommand.next.target(in: model(active: nil)) == a.id)
        #expect(WorkspaceSwitchCommand.previous.target(in: model(active: nil)) == c.id)
        #expect(WorkspaceSwitchCommand.next.target(in: WorkspaceModel()) == nil)
        #expect(WorkspaceSwitchCommand.index(1).target(in: WorkspaceModel()) == nil)
    }
}
