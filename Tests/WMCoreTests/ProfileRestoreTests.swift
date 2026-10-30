import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Undo of a profile delete puts back the same profile: same id, same name (P6.156).
@Suite struct ProfileRestoreTests {
    static let display = DisplayIdentity(uuid: "RESTORE-D1", name: "Main",
                                         frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                         isMain: true, isBuiltIn: true)

    static func makeService() -> (ProfileService, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)")
        return (ProfileService(store: ProfileStore(folder: folder)), folder)
    }

    @Test func deleteThenRestoreKeepsIdAndName() throws {
        let (svc, folder) = Self.makeService()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try svc.createBlank(name: "Work", displays: [Self.display])

        let deleted = try svc.delete("Work")
        #expect(svc.list().isEmpty)

        let restored = try svc.restore(deleted)
        #expect(restored.id == original.id)
        #expect(restored.name == "Work")
        #expect(try svc.show(original.id.uuidString).name == "Work")
        #expect(svc.list().map(\.id) == [original.id])
    }

    @Test func restoreOverExistingIdThrows() throws {
        let (svc, folder) = Self.makeService()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try svc.createBlank(name: "Work", displays: [Self.display])

        // The profile is still there, so putting a copy of it back must fail and leave the file alone.
        #expect(throws: (any Error).self) { try svc.restore(original) }
        #expect(svc.list().count == 1)

        let store = ProfileStore(folder: folder)
        #expect(throws: (any Error).self) { try store.restore(original) }
    }

    @Test func restoreWithNameTakenByAnotherProfileThrows() throws {
        let (svc, folder) = Self.makeService()
        defer { try? FileManager.default.removeItem(at: folder) }
        let work = try svc.createBlank(name: "Work", displays: [Self.display])
        _ = try svc.delete("Work")
        _ = try svc.createBlank(name: "Work", displays: [Self.display])

        #expect(throws: (any Error).self) { try svc.restore(work) }
        #expect(svc.list().count == 1)
    }
}
