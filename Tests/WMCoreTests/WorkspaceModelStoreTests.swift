import Foundation
import Testing
@testable import WMCore

@Suite struct WorkspaceModelStoreTests {
    static let a = UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000A1")!
    static let b = UUID(uuidString: "6B0F0C2A-0000-4000-8000-0000000000B1")!
    static let frame = CGRect(x: 100, y: 120, width: 800, height: 600)

    static func model() -> WorkspaceModel {
        WorkspaceModel(
            workspaces: [
                Workspace(id: a, name: "Code", apps: ["com.apple.dt.Xcode"],
                          windows: [WorkspaceWindowRef(windowID: 1, pid: 10, bundleID: "x", title: "t"),
                                    WorkspaceWindowRef(windowID: 2, pid: 11)]),
                Workspace(id: b, name: "Chat", windows: [WorkspaceWindowRef(windowID: 3, pid: 12),
                                                          WorkspaceWindowRef(windowID: 4, pid: 13)]),
            ],
            activeWorkspaceID: a,
            hiddenRecords: [
                HiddenWindowRecord(windowID: 3, pid: 12, method: .appHidden, originalFrame: frame, workspaceID: b),
                HiddenWindowRecord(windowID: 4, pid: 13, method: .parked, originalFrame: frame, workspaceID: b),
                HiddenWindowRecord(windowID: 99, pid: 77, method: .parked, originalFrame: frame),
            ])
    }

    static func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wm-ws-\(UUID().uuidString)")
    }

    @Test func saveLoadRoundTrip() throws {
        let folder = Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkspaceModelStore(folder: folder)
        #expect(try store.load() == nil)
        try store.save(Self.model())
        #expect(try store.load() == Self.model())
        var changed = Self.model()
        changed.activeWorkspaceID = Self.b
        try store.save(changed)
        #expect(try store.load()?.activeWorkspaceID == Self.b)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(leftovers == ["workspaces.json"])
    }

    @Test func corruptAndNewerFilesThrow() throws {
        let folder = Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkspaceModelStore(folder: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: store.fileURL)
        #expect(throws: WorkspaceModelStoreError.self) { try store.load() }
        try Data(#"{"schemaVersion":99,"workspaces":[],"hiddenRecords":[]}"#.utf8).write(to: store.fileURL)
        #expect(throws: WorkspaceModelStoreError.newerSchema(99)) { try store.load() }
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func recoverUnhidesParksAndDropsGone() {
        let live = [
            VirtualLiveWindow(windowID: 3, pid: 12, frame: Self.frame, isOnScreen: false),
            VirtualLiveWindow(windowID: 4, pid: 13, frame: CGRect(x: 5000, y: 5000, width: 800, height: 600)),
            VirtualLiveWindow(windowID: 1, pid: 10, frame: Self.frame),
        ]
        let plan = WorkspaceModelStore.recover(Self.model(), live: live)
        #expect(plan.actions == [.unhideApp(pid: 12), .restoreFrame(windowID: 4, pid: 13, frame: Self.frame)])
        #expect(plan.droppedRecords.map(\.windowID) == [99])
        #expect(plan.model.hiddenRecords.isEmpty)
        #expect(plan.model.workspaces[0].windows.map(\.windowID) == [1])
        #expect(plan.model.workspaces[1].windows.map(\.windowID) == [3, 4])
    }

    @Test func recoverSkipsParkedWindowAlreadyInPlace() {
        let live = [VirtualLiveWindow(windowID: 4, pid: 13, frame: Self.frame.offsetBy(dx: 1, dy: 1))]
        let plan = WorkspaceModelStore.recover(Self.model(), live: live)
        #expect(plan.actions.isEmpty)
    }

    @Test func reassertRestoresActiveAndHidesOthers() {
        var model = Self.model()
        model.hiddenRecords = [
            HiddenWindowRecord(windowID: 2, pid: 11, method: .parked, originalFrame: Self.frame, workspaceID: Self.a),
        ]
        let live = [
            VirtualLiveWindow(windowID: 1, pid: 10, frame: Self.frame, isOnScreen: false),
            VirtualLiveWindow(windowID: 2, pid: 11, frame: CGRect(x: 9000, y: 9000, width: 800, height: 600)),
            VirtualLiveWindow(windowID: 3, pid: 12, frame: Self.frame),
            VirtualLiveWindow(windowID: 4, pid: 13, frame: Self.frame, isOnScreen: false),
            VirtualLiveWindow(windowID: 50, pid: 14, frame: Self.frame),
        ]
        let actions = WorkspaceModelStore.reassertActive(model, live: live)
        #expect(actions == [.unhideApp(pid: 10), .restoreFrame(windowID: 2, pid: 11, frame: Self.frame),
                            .hideWindow(windowID: 3, pid: 12)])
    }

    @Test func reassertWithoutActiveWorkspaceDoesNothing() {
        var model = Self.model()
        model.activeWorkspaceID = nil
        #expect(WorkspaceModelStore.reassertActive(model, live: [VirtualLiveWindow(windowID: 3, pid: 12, frame: Self.frame)]).isEmpty)
    }
}
