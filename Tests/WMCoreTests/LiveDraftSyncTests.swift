import CoreGraphics
import Foundation
import Testing
@testable import WMCore

private let dispA = DisplayIdentity(uuid: "A", name: "Studio", frame: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 2000, height: 1000), isMain: true, isBuiltIn: false)
private let dispB = DisplayIdentity(uuid: "B", name: "Dell", frame: CGRect(x: 2000, y: 0, width: 1000, height: 1000),
                                    visibleFrame: CGRect(x: 2000, y: 0, width: 1000, height: 1000), isMain: false, isBuiltIn: false)
private let safari = AppRef(bundleID: "com.apple.Safari", name: "Safari")
private let terminal = AppRef(bundleID: "com.apple.Terminal", name: "Terminal")
private let notes = AppRef(bundleID: "com.apple.Notes", name: "Notes")

private func win(_ app: AppRef, title: String?, frame: CGRect, display: String = "A", stage: SavedStage? = nil) -> WindowSnapshot {
    WindowSnapshot(app: app, title: title, displayUUID: display, frame: frame,
                   relativeFrame: CGRect(x: frame.minX / 2000, y: frame.minY / 1000, width: frame.width / 2000, height: frame.height / 1000),
                   placement: .desktop(number: 1), stage: stage)
}

private func profile(_ windows: [WindowSnapshot], stage: Bool? = nil) -> Profile {
    Profile(name: "Live", monitorSetKey: "k", displays: [dispA, dispB],
            spaces: [SpaceSnapshot(displayUUID: "A", position: 0, kind: .desktop, desktopNumber: 1)],
            windows: windows, stageManagerOn: stage)
}

private let left = CGRect(x: 0, y: 0, width: 800, height: 600)
private let right = CGRect(x: 900, y: 0, width: 800, height: 600)

@Suite struct LiveDraftSyncTests {
    @Test func movedWindowUpdatesFrameAndKeepsItsIdentity() {
        let draft = win(safari, title: "Home", frame: left)
        let live = win(safari, title: "Home", frame: CGRect(x: 100, y: 50, width: 900, height: 700))
        let out = LiveDraftSync.outcome(draft: profile([draft]), scanned: profile([live]))
        #expect(out.profile.windows.count == 1)
        #expect(out.profile.windows[0].id == draft.id)
        #expect(out.profile.windows[0].frame == live.frame)
        #expect(out.profile.windows[0].relativeFrame == live.relativeFrame)
        #expect(out.updated == 1 && out.added == 0 && out.removed == 0)
        #expect(out.changed)
    }

    @Test func newWindowIsAddedAndClosedWindowIsRemoved() {
        let kept = win(safari, title: "Home", frame: left)
        let closed = win(notes, title: "Todo", frame: right)
        let fresh = win(terminal, title: "zsh", frame: right)
        let out = LiveDraftSync.outcome(draft: profile([kept, closed]), scanned: profile([kept, fresh]))
        #expect(out.profile.windows.map(\.app) == [safari, terminal])
        #expect(out.profile.windows[1].id == fresh.id)
        #expect(out.added == 1)
        #expect(out.removed == 1)
        #expect(out.updated == 0)
    }

    @Test func editedWindowIsKeptUntouched() {
        let draft = win(safari, title: "Home", frame: left)
        let moved = win(safari, title: "Home", frame: right)
        let out = LiveDraftSync.outcome(draft: profile([draft]), scanned: profile([moved]),
                                        manuallyEdited: [draft.id])
        #expect(out.profile.windows == [draft])
        #expect(out.updated == 0 && out.added == 0)
        #expect(!out.changed)
    }

    @Test func editedWindowMissingFromTheScanIsKept() {
        let draft = win(notes, title: "Todo", frame: left)
        let out = LiveDraftSync.outcome(draft: profile([draft]), scanned: profile([]), manuallyEdited: [draft.id])
        #expect(out.profile.windows == [draft])
        #expect(out.removed == 0)
    }

    @Test func plannedWindowIsNeverRemovedOrMoved() {
        var planned = win(notes, title: nil, frame: left)
        planned.origin = .planned
        let out = LiveDraftSync.outcome(draft: profile([planned]), scanned: profile([]))
        #expect(out.profile.windows == [planned])
    }

    @Test func twoIdenticalTerminalWindowsMatchByNearestFrame() {
        let t1 = win(terminal, title: "zsh", frame: left)
        let t2 = win(terminal, title: "zsh", frame: right)
        // The live windows come back in the opposite order, and each has moved a little.
        let live1 = win(terminal, title: "zsh", frame: CGRect(x: 905, y: 10, width: 800, height: 600))
        let live2 = win(terminal, title: "zsh", frame: CGRect(x: 10, y: 0, width: 800, height: 600))
        let out = LiveDraftSync.outcome(draft: profile([t1, t2]), scanned: profile([live1, live2]))
        #expect(out.profile.windows.count == 2)
        #expect(out.profile.windows[0].id == t1.id)
        #expect(out.profile.windows[0].frame == live2.frame)
        #expect(out.profile.windows[1].id == t2.id)
        #expect(out.profile.windows[1].frame == live1.frame)
        #expect(out.added == 0 && out.removed == 0)
    }

    @Test func stageInfoAndDisplaysComeFromTheScan() {
        let draft = win(safari, title: "Home", frame: left)
        let stage = SavedStage(group: 1, isActive: false, isHeuristic: true)
        var scanned = profile([win(safari, title: "Home", frame: left, stage: stage)], stage: true)
        scanned.displays = [dispA]
        scanned.monitorSetKey = "only-a"
        let out = LiveDraftSync.outcome(draft: profile([draft]), scanned: scanned)
        #expect(out.profile.windows[0].stage == stage)
        #expect(out.profile.stageManagerOn == true)
        #expect(out.profile.displays == [dispA])
        #expect(out.profile.monitorSetKey == "only-a")
    }

    @Test func draftSettingsAreKept() {
        var draft = profile([])
        draft.name = "Work"
        draft.icon = "star"
        draft.options.restoreSpaces = false
        draft.launchPlan = LaunchPlan(mode: .sequential)
        let out = LiveDraftSync.outcome(draft: draft, scanned: profile([win(safari, title: "Home", frame: left)]))
        #expect(out.profile.name == "Work")
        #expect(out.profile.icon == "star")
        #expect(!out.profile.options.restoreSpaces)
        #expect(out.profile.launchPlan == draft.launchPlan)
    }

    @Test func deletedWindowDoesNotComeBackWhileItIsOpen() {
        let gone = win(safari, title: "Home", frame: left)
        let live = win(safari, title: "Home", frame: left)
        let out = LiveDraftSync.outcome(draft: profile([]), scanned: profile([live]), dismissed: [gone])
        #expect(out.profile.windows.isEmpty)
        #expect(out.stillDismissed == [gone])
        // Once the app has closed, the dismissal is no longer needed.
        let later = LiveDraftSync.outcome(draft: profile([]), scanned: profile([]), dismissed: [gone])
        #expect(later.stillDismissed.isEmpty)
    }

    @Test func noChangeReportsNothing() {
        let draft = win(safari, title: "Home", frame: left)
        let out = LiveDraftSync.outcome(draft: profile([draft]), scanned: profile([win(safari, title: "Home", frame: left)]))
        #expect(!out.changed)
        #expect(out.profile.windows == [draft])
    }

    @Test func liveRefreshIsNotAnUndoEntry() throws {
        var s = DraftSession(initial: DraftSession.blankProfile(displays: [dispA]), isNew: true)
        try s.edit(kind: "addDesktop") { _ = try $0.addDesktop(onDisplay: "A") }
        var refreshed = s.profile
        refreshed.windows = [win(safari, title: "Home", frame: right)]
        s.refreshLive(refreshed)
        #expect(s.profile == refreshed)
        #expect(s.isDirty)
        s.undo()
        #expect(s.profile.spaces.count == 1)
    }

    @Test func liveRefreshOfACleanDraftIsNotDirty() {
        var s = DraftSession(initial: profile([]), isNew: true)
        s.refreshLive(profile([win(safari, title: "Home", frame: right)]))
        #expect(!s.isDirty)
        #expect(!s.canUndo)
    }
}
