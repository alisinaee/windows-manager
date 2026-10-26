import Foundation
import Testing
@testable import WMCore

@Suite struct WorkspaceModelMergeTests {
    static let a = UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000A1")!
    static let b = UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000B1")!
    static let c = UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000C1")!
    static let frame = CGRect(x: 100, y: 120, width: 800, height: 600)

    /// The model as it was when the switch started: workspaces a and b, a is active.
    static func snapshot() -> WorkspaceModel {
        WorkspaceModel(
            workspaces: [
                Workspace(id: a, name: "Code", apps: ["com.apple.dt.Xcode"], windows: [WorkspaceWindowRef(windowID: 1, pid: 10)]),
                Workspace(id: b, name: "Chat", windows: [WorkspaceWindowRef(windowID: 3, pid: 12)]),
            ],
            activeWorkspaceID: a)
    }

    /// What the switch saves: b is now active, window 3 (of b) is hidden.
    static func switchOutput() -> WorkspaceModel {
        var model = snapshot()
        model.activeWorkspaceID = b
        model.hiddenRecords = [
            HiddenWindowRecord(windowID: 1, pid: 10, method: .appHidden, originalFrame: frame, workspaceID: a),
            HiddenWindowRecord(windowID: 3, pid: 12, method: .parked, originalFrame: frame, workspaceID: b),
        ]
        return model
    }

    @Test func userAddedWorkspaceDuringSwitchIsKept() {
        var user = Self.snapshot()
        user.workspaces.append(Workspace(id: Self.c, name: "Mail"))

        let merged = WorkspaceModelMerge.merge(userEdited: user, switchResult: Self.switchOutput())

        #expect(merged.workspaces.map { $0.id } == [Self.a, Self.b, Self.c])
        #expect(merged.workspaces.last?.name == "Mail")
        #expect(merged.activeWorkspaceID == Self.b)
        #expect(merged.hiddenRecords == Self.switchOutput().hiddenRecords)
    }

    @Test func userDeletedWorkspaceDuringSwitchIsRemoved() {
        var user = Self.snapshot()
        user.workspaces.removeAll { $0.id == Self.b }

        let merged = WorkspaceModelMerge.merge(userEdited: user, switchResult: Self.switchOutput())

        #expect(merged.workspaces.map { $0.id } == [Self.a])
        // The switch made b active; b is gone, so no active workspace is left.
        #expect(merged.activeWorkspaceID == nil)
    }

    @Test func recordsForDeletedWorkspacesAreDropped() {
        var user = Self.snapshot()
        user.workspaces.removeAll { $0.id == Self.b }

        let merged = WorkspaceModelMerge.merge(userEdited: user, switchResult: Self.switchOutput())

        #expect(merged.hiddenRecords.map { $0.windowID } == [1])
        #expect(merged.hiddenRecords.allSatisfy { $0.workspaceID != Self.b })
    }

    @Test func recordsWithoutWorkspaceAreKept() {
        var output = Self.switchOutput()
        output.hiddenRecords.append(HiddenWindowRecord(windowID: 9, pid: 99, method: .parked, originalFrame: Self.frame))

        let merged = WorkspaceModelMerge.merge(userEdited: Self.snapshot(), switchResult: output)

        #expect(merged.hiddenRecords.map { $0.windowID }.contains(9))
    }

    @Test func renameDuringSwitchIsKept() {
        var user = Self.snapshot()
        user.workspaces[1].name = "Chat renamed"

        let merged = WorkspaceModelMerge.merge(userEdited: user, switchResult: Self.switchOutput())

        #expect(merged.workspace(Self.b)?.name == "Chat renamed")
        #expect(merged.activeWorkspaceID == Self.b)
    }

    @Test func appAssignedDuringSwitchIsKept() {
        var user = Self.snapshot()
        user.workspaces[0].apps.append("com.apple.Safari")

        let merged = WorkspaceModelMerge.merge(userEdited: user, switchResult: Self.switchOutput())

        #expect(merged.workspace(Self.a)?.apps == ["com.apple.dt.Xcode", "com.apple.Safari"])
    }

    @Test func hiddenAndActiveComeFromTheSwitch() {
        // The user's copy still shows the old state: a active, nothing hidden.
        let user = Self.snapshot()

        let merged = WorkspaceModelMerge.merge(userEdited: user, switchResult: Self.switchOutput())

        #expect(merged.activeWorkspaceID == Self.b)
        #expect(merged.hiddenRecords == Self.switchOutput().hiddenRecords)
    }

    @Test func noUserEditsGiveTheSwitchState() {
        let merged = WorkspaceModelMerge.merge(userEdited: Self.snapshot(), switchResult: Self.switchOutput())

        #expect(merged == Self.switchOutput())
    }
}
