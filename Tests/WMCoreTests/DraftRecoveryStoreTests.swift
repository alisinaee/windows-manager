import Foundation
import Testing
@testable import WMCore

@Suite struct DraftRecoveryStoreTests {
    private func store() -> DraftRecoveryStore {
        DraftRecoveryStore(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-drafts-\(UUID().uuidString)", isDirectory: true))
    }

    private func profile(_ name: String = "Work") -> Profile {
        DraftSession.blankProfile(name: name, displays: [], now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func writeReadRoundTripAndDelete() throws {
        let s = store(); let p = profile()
        let base = Date(timeIntervalSince1970: 1_700_000_100.5), at = Date(timeIntervalSince1970: 1_700_000_200)
        try s.write(p, baseUpdatedAt: base, savedAt: at)
        #expect(s.file(for: p.id).lastPathComponent == "\(p.id.uuidString).draft.json")
        let back = try #require(s.read(p.id))
        #expect(back.profile == p && back.baseUpdatedAt == base && back.savedAt == at)
        #expect(s.draftIDs() == [p.id])
        s.delete(p.id)
        #expect(s.read(p.id) == nil && s.draftIDs().isEmpty)
    }

    @Test func overwriteKeepsLatestAndMissingReadsNil() throws {
        let s = store(); var p = profile()
        #expect(s.read(p.id) == nil)
        try s.write(p, baseUpdatedAt: nil)
        p.name = "Changed"
        try s.write(p, baseUpdatedAt: nil)
        #expect(s.read(p.id)?.profile.name == "Changed")
    }

    @Test func corruptFileReadsAsNil() throws {
        let s = store(); let p = profile()
        try s.write(p, baseUpdatedAt: nil)
        try Data("{nope".utf8).write(to: s.file(for: p.id))
        #expect(s.read(p.id) == nil)
    }

    @Test func differsAndRecoverable() throws {
        let s = store(); let saved = profile(); var draft = saved
        #expect(!DraftRecoveryStore.differs(saved, from: saved))
        #expect(DraftRecoveryStore.differs(saved, from: nil))
        try s.write(draft, baseUpdatedAt: saved.updatedAt)
        #expect(s.recoverable(saved.id, saved: saved) == nil)      // identical: dropped
        #expect(s.read(saved.id) == nil)
        draft.name = "Edited"
        try s.write(draft, baseUpdatedAt: saved.updatedAt)
        #expect(s.recoverable(saved.id, saved: saved)?.profile.name == "Edited")
        #expect(s.recoverable(saved.id, saved: nil) != nil)         // never-saved profile
    }

    @Test func staleness() {
        let base = Date(timeIntervalSince1970: 1000)
        let d = RecoveredDraft(profile: profile(), baseUpdatedAt: base, savedAt: base)
        #expect(!DraftRecoveryStore.isStale(d, savedUpdatedAt: base))
        #expect(DraftRecoveryStore.isStale(d, savedUpdatedAt: base.addingTimeInterval(5)))
        #expect(!DraftRecoveryStore.isStale(d, savedUpdatedAt: nil))
        let none = RecoveredDraft(profile: profile(), baseUpdatedAt: nil, savedAt: base)
        #expect(!DraftRecoveryStore.isStale(none, savedUpdatedAt: base))
    }
}
