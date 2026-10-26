import CoreGraphics
import Foundation
import Testing
@testable import WMCore

private let dispA = DisplayIdentity(uuid: "A", name: "Studio", frame: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 2000, height: 1000), isMain: true, isBuiltIn: false)
private let dispB = DisplayIdentity(uuid: "B", name: "Dell", frame: CGRect(x: 2000, y: 0, width: 1000, height: 1000),
                                    visibleFrame: CGRect(x: 2000, y: 0, width: 1000, height: 1000), isMain: false, isBuiltIn: false)
private let safari = AppRef(bundleID: "com.apple.Safari", name: "Safari")

private final class Clock { var now: TimeInterval = 0 }

@Suite struct DraftSessionTests {
    private func session(_ clock: Clock = Clock()) -> DraftSession {
        DraftSession(initial: DraftSession.blankProfile(displays: [dispA, dispB]), isNew: true,
                     clock: { clock.now })
    }

    @Test func blankHasOneDesktopPerDisplayAndIsValid() {
        let p = DraftSession.blankProfile(displays: [dispA, dispB])
        #expect(p.spaces.count == 2)
        #expect(p.validate().isEmpty)
        #expect(p.options.addMissingDesktops)
        #expect(!ProfileDraftCheck.blocksSaving(ProfileDraftCheck.check(p)))
    }

    @Test func cleanUntilEditedAndAfterUndo() throws {
        var s = session()
        #expect(!s.isDirty)
        try s.edit(kind: "addDesktop") { _ = try $0.addDesktop(onDisplay: "A") }
        #expect(s.isDirty)
        #expect(s.profile.spaces.count == 3)
        s.undo()
        #expect(!s.isDirty)
        s.redo()
        #expect(s.isDirty)
    }

    @Test func failedEditLeavesDraftAndHistoryAlone() {
        var s = session()
        #expect(throws: ProfileDraftError.self) { try s.edit { _ = try $0.addDesktop(onDisplay: "nope") } }
        #expect(!s.isDirty)
        #expect(!s.canUndo)
    }

    @Test func noOpEditRecordsNothing() throws {
        var s = session()
        try s.edit { _ in }
        #expect(!s.canUndo)
    }

    @Test func sameKindCoalescesWithinWindow() throws {
        let clock = Clock()
        var s = session(clock)
        let id = try s.edit(kind: "addWindow") { try $0.addPlannedWindow(app: safari, onDisplay: "A", desktop: 1) }
        clock.now = 10
        try s.edit(kind: "moveWindow") { try $0.setRelativeFrame(ofWindow: id, relativeFrame: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)) }
        clock.now = 10.1
        try s.edit(kind: "moveWindow") { try $0.setRelativeFrame(ofWindow: id, relativeFrame: CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.5)) }
        #expect(s.history.undoCount == 2)
        clock.now = 20
        try s.edit(kind: "moveWindow") { try $0.setRelativeFrame(ofWindow: id, relativeFrame: CGRect(x: 0.3, y: 0.1, width: 0.5, height: 0.5)) }
        #expect(s.history.undoCount == 3)
    }

    @Test func saveBlockedByEmptyNameAndErrors() throws {
        let blank = DraftSession(initial: DraftSession.blankProfile(name: "  ", displays: [dispA]), isNew: true)
        #expect(throws: DraftSaveRefusal.emptyName) { try blank.prepareSave(otherNames: []) }
        var s = session()
        #expect(throws: ProfileDraftError.self) { try s.edit { try $0.setName("") } }

        // A full-screen Space without an owner is an error.
        var broken = DraftSession.blankProfile(displays: [dispA])
        broken.spaces.append(SpaceSnapshot(displayUUID: "A", position: 1, kind: .fullScreen))
        let b = DraftSession(initial: broken, isNew: true)
        do { _ = try b.prepareSave(otherNames: []); Issue.record("expected refusal") }
        catch let DraftSaveRefusal.blocked(issues) { #expect(!issues.isEmpty) }
    }

    @Test func saveMakesNameUniqueAndMarkSavedCleans() throws {
        var s = session()
        try s.edit { try $0.setName(" Work ") }
        let ready = try s.prepareSave(otherNames: ["work", "Work 2"])
        #expect(ready.name == "Work 3")
        s.markSaved(ready)
        #expect(!s.isDirty && !s.canUndo && !s.isNew)
    }

    @Test func warningsDoNotBlockSaving() throws {
        let s = session()   // empty Desktops are warnings only
        #expect(!ProfileDraftCheck.warnings(s.issues()).isEmpty)
        _ = try s.prepareSave(otherNames: [])
    }

    @Test func copyGetsNewIdFreeNameNoHotkey() {
        var src = DraftSession.blankProfile(name: "Home", displays: [dispA])
        src.options.hotkey = "cmd+1"
        let copy = DraftSession.copyProfile(of: src, existingNames: ["Home", "Home copy"])
        #expect(copy.id != src.id)
        #expect(copy.name == "Home copy 2")
        #expect(copy.options.hotkey == nil)
    }
}
