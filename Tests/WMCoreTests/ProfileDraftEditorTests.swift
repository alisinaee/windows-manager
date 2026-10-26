import CoreGraphics
import Foundation
import Testing
@testable import WMCore

private let dispA = DisplayIdentity(uuid: "A", name: "Studio", frame: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                                    visibleFrame: CGRect(x: 0, y: 100, width: 2000, height: 900), isMain: true, isBuiltIn: false)
private let dispB = DisplayIdentity(uuid: "B", name: "Dell", frame: CGRect(x: 2000, y: 0, width: 1000, height: 1000),
                                    visibleFrame: CGRect(x: 2000, y: 0, width: 1000, height: 1000), isMain: false, isBuiltIn: false)
private let safari = AppRef(bundleID: "com.apple.Safari", name: "Safari")
private let xcode = AppRef(bundleID: "com.apple.dt.Xcode", name: "Xcode")
private let notes = AppRef(bundleID: "com.apple.Notes", name: "Notes")

private func win(_ app: AppRef, _ n: Int, display: String = "A", rel: CGRect = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)) -> WindowSnapshot {
    WindowSnapshot(app: app, displayUUID: display, frame: rel, relativeFrame: rel, placement: .desktop(number: n))
}

/// Display A: D1 (pos0), D2 (pos1), FS xcode (pos2), D3 (pos3), FS notes (pos4). Display B: D1.
private struct Fixture {
    var profile: Profile
    let safari1: WindowSnapshot, safari2: WindowSnapshot, safari3: WindowSnapshot
    let xcodeFS: WindowSnapshot, notesFS: WindowSnapshot, bWin: WindowSnapshot

    init() {
        safari1 = win(safari, 1); safari2 = win(safari, 2, rel: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        safari3 = win(safari, 3)
        var x = win(xcode, 1); x.isFullScreen = true; x.placement = .fullScreen(position: 2)
        var nt = win(notes, 1); nt.isFullScreen = true; nt.placement = .fullScreen(position: 4)
        xcodeFS = x; notesFS = nt
        bWin = win(notes, 1, display: "B")
        profile = Profile(name: "T", monitorSetKey: "k", displays: [dispA, dispB], spaces: [
            SpaceSnapshot(displayUUID: "A", position: 0, kind: .desktop, desktopNumber: 1),
            SpaceSnapshot(displayUUID: "A", position: 1, kind: .desktop, desktopNumber: 2),
            SpaceSnapshot(displayUUID: "A", position: 2, kind: .fullScreen, fullScreenWindowIDs: [x.id]),
            SpaceSnapshot(displayUUID: "A", position: 3, kind: .desktop, desktopNumber: 3),
            SpaceSnapshot(displayUUID: "A", position: 4, kind: .fullScreen, fullScreenWindowIDs: [nt.id]),
            SpaceSnapshot(displayUUID: "B", position: 0, kind: .desktop, desktopNumber: 1),
        ], windows: [safari1, safari2, safari3, x, nt, bWin])
    }
}

private func place(_ p: Profile, _ id: UUID) -> SpacePlacement { p.windows.first { $0.id == id }!.placement }

@Suite struct ProfileDraftEditorTests {
    @Test func fixtureIsValid() {
        #expect(Fixture().profile.validate().isEmpty)
    }

    @Test func addDesktopAppendsAfterLastDesktopAndShiftsFullScreen() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        let n = try e.addDesktop(onDisplay: "A")
        #expect(n == 4)
        let spaces = e.profile.spaces(onDisplay: "A")
        #expect(spaces.map(\.kind) == [.desktop, .desktop, .fullScreen, .desktop, .desktop, .fullScreen])
        #expect(spaces.map(\.position) == [0, 1, 2, 3, 4, 5])
        #expect(spaces.compactMap(\.desktopNumber) == [1, 2, 3, 4])
        #expect(place(e.profile, f.notesFS.id) == .fullScreen(position: 5))
        #expect(place(e.profile, f.xcodeFS.id) == .fullScreen(position: 2))
        #expect(e.profile.validate().isEmpty)
    }

    @Test func addDesktopInsertingInTheMiddleRenumbersWindows() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        #expect(try e.addDesktop(onDisplay: "A", atNumber: 2) == 2)
        #expect(place(e.profile, f.safari1.id) == .desktop(number: 1))
        #expect(place(e.profile, f.safari2.id) == .desktop(number: 3))
        #expect(place(e.profile, f.safari3.id) == .desktop(number: 4))
        #expect(place(e.profile, f.xcodeFS.id) == .fullScreen(position: 3))
        #expect(e.profile.spaces(onDisplay: "A").compactMap(\.desktopNumber) == [1, 2, 3, 4])
        #expect(e.profile.spaces(onDisplay: "B").count == 1)
        #expect(e.profile.validate().isEmpty)
    }

    @Test func addDesktopStopsAtSixteen() throws {
        var e = ProfileDraftEditor(Fixture().profile)
        for _ in 0..<13 { try e.addDesktop(onDisplay: "A") }
        #expect(e.profile.spaces(onDisplay: "A").filter { $0.kind == .desktop }.count == 16)
        #expect(throws: ProfileDraftError.tooManyDesktops(max: 16)) { try e.addDesktop(onDisplay: "A") }
        #expect(throws: ProfileDraftError.unknownDisplay("Z")) { try e.addDesktop(onDisplay: "Z") }
    }

    @Test func deleteDesktopMovesWindowsAndRenumbers() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        try e.deleteDesktop(onDisplay: "A", number: 2, moveWindowsTo: 1)
        #expect(place(e.profile, f.safari2.id) == .desktop(number: 1))
        #expect(place(e.profile, f.safari3.id) == .desktop(number: 2))
        #expect(place(e.profile, f.xcodeFS.id) == .fullScreen(position: 1))
        #expect(place(e.profile, f.notesFS.id) == .fullScreen(position: 3))
        let spaces = e.profile.spaces(onDisplay: "A")
        #expect(spaces.map(\.position) == [0, 1, 2, 3])
        #expect(spaces.compactMap(\.desktopNumber) == [1, 2])
        #expect(e.profile.windows.count == 6)
        #expect(e.profile.validate().isEmpty)
    }

    @Test func deleteDesktopWithoutTargetDeletesItsWindowsOnly() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        try e.deleteDesktop(onDisplay: "A", number: 3)
        #expect(!e.profile.windows.contains { $0.id == f.safari3.id })
        #expect(e.profile.windows.count == 5)
        #expect(place(e.profile, f.notesFS.id) == .fullScreen(position: 3))
        #expect(e.profile.validate().isEmpty)
    }

    @Test func deleteDesktopRejectsBadInput() throws {
        var e = ProfileDraftEditor(Fixture().profile)
        let before = e.profile
        #expect(throws: ProfileDraftError.sameDesktop) { try e.deleteDesktop(onDisplay: "A", number: 2, moveWindowsTo: 2) }
        #expect(throws: ProfileDraftError.unknownDesktop(display: "A", number: 9)) { try e.deleteDesktop(onDisplay: "A", number: 1, moveWindowsTo: 9) }
        #expect(throws: ProfileDraftError.lastDesktop) { try e.deleteDesktop(onDisplay: "B", number: 1) }
        #expect(e.profile == before)
    }

    @Test func moveDesktopRenumbersAndKeepsFullScreenSlots() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        try e.moveDesktop(onDisplay: "A", number: 3, toNumber: 1)
        #expect(place(e.profile, f.safari3.id) == .desktop(number: 1))
        #expect(place(e.profile, f.safari1.id) == .desktop(number: 2))
        #expect(place(e.profile, f.safari2.id) == .desktop(number: 3))
        #expect(place(e.profile, f.xcodeFS.id) == .fullScreen(position: 2))
        #expect(place(e.profile, f.notesFS.id) == .fullScreen(position: 4))
        let spaces = e.profile.spaces(onDisplay: "A")
        #expect(spaces.map(\.kind) == [.desktop, .desktop, .fullScreen, .desktop, .fullScreen])
        #expect(spaces.compactMap(\.desktopNumber) == [1, 2, 3])
        #expect(e.profile.validate().isEmpty)
    }

    @Test func moveDesktopDown() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        try e.moveDesktop(onDisplay: "A", number: 1, toNumber: 3)
        #expect(place(e.profile, f.safari1.id) == .desktop(number: 3))
        #expect(place(e.profile, f.safari2.id) == .desktop(number: 1))
        #expect(place(e.profile, f.safari3.id) == .desktop(number: 2))
    }

    @Test func fullScreenAddKeepsOwnersAndPositions() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        let pos = try e.makeFullScreen(windowID: f.safari2.id, afterPosition: 1)
        #expect(pos == 2)
        let w = e.profile.windows.first { $0.id == f.safari2.id }!
        #expect(w.isFullScreen && w.relativeFrame == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(w.placement == .fullScreen(position: 2))
        #expect(e.profile.spaces(onDisplay: "A")[2].fullScreenWindowIDs == [f.safari2.id])
        #expect(place(e.profile, f.xcodeFS.id) == .fullScreen(position: 3))
        #expect(place(e.profile, f.safari3.id) == .desktop(number: 3))
        #expect(e.profile.spaces(onDisplay: "A").map(\.position) == [0, 1, 2, 3, 4, 5])
        #expect(e.profile.validate().isEmpty)
        #expect(throws: ProfileDraftError.windowAlreadyFullScreen(f.safari2.id)) { try e.makeFullScreen(windowID: f.safari2.id) }
    }

    @Test func fullScreenReorderKeepsOwnerIds() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        try e.moveFullScreenSpace(onDisplay: "A", position: 4, toIndex: 0)
        let spaces = e.profile.spaces(onDisplay: "A")
        #expect(spaces[2].fullScreenWindowIDs == [f.notesFS.id])
        #expect(spaces[4].fullScreenWindowIDs == [f.xcodeFS.id])
        #expect(place(e.profile, f.notesFS.id) == .fullScreen(position: 2))
        #expect(place(e.profile, f.xcodeFS.id) == .fullScreen(position: 4))
        #expect(spaces.compactMap(\.desktopNumber) == [1, 2, 3])
        #expect(e.profile.validate().isEmpty)
        #expect(throws: ProfileDraftError.notFullScreenSpace(position: 0)) { try e.moveFullScreenSpace(onDisplay: "A", position: 0, toIndex: 1) }
    }

    @Test func removeFullScreenSpaceDemotesOrDeletesOwners() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        try e.removeFullScreenSpace(onDisplay: "A", position: 2, removal: .moveWindows(toDesktop: 2))
        let w = e.profile.windows.first { $0.id == f.xcodeFS.id }!
        #expect(!w.isFullScreen && w.placement == .desktop(number: 2))
        #expect(place(e.profile, f.notesFS.id) == .fullScreen(position: 3))
        #expect(e.profile.validate().isEmpty)
        try e.removeFullScreenSpace(onDisplay: "A", position: 3, removal: .deleteWindows)
        #expect(!e.profile.windows.contains { $0.id == f.notesFS.id })
        #expect(e.profile.validate().isEmpty)
    }

    @Test func removingFullScreenOwnerRemovesItsSpace() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        try e.removeWindow(f.xcodeFS.id)
        #expect(e.profile.spaces(onDisplay: "A").map(\.position) == [0, 1, 2, 3])
        #expect(place(e.profile, f.notesFS.id) == .fullScreen(position: 3))
        #expect(e.profile.validate().isEmpty)
    }

    @Test func addPlannedWindowFromRelativeAndFrame() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        let id = try e.addPlannedWindow(app: xcode, onDisplay: "A", desktop: 2,
                                        relativeFrame: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        let w = e.profile.windows.first { $0.id == id }!
        #expect(w.origin == .planned && w.titleMatch == .any && w.title == nil)
        #expect(w.placement == .desktop(number: 2))
        #expect(w.frame == CGRect(x: 1000, y: 550, width: 1000, height: 450))
        #expect(w.indexInApp == 1)
        let id2 = try e.addPlannedWindow(app: xcode, onDisplay: "B", desktop: 1, frame: CGRect(x: 2500, y: 0, width: 500, height: 500))
        let w2 = e.profile.windows.first { $0.id == id2 }!
        #expect(w2.relativeFrame == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(w2.indexInApp == 2)
        let id3 = try e.addPlannedWindow(app: safari, onDisplay: "B", desktop: 1)
        #expect(e.profile.windows.first { $0.id == id3 }!.relativeFrame == ProfileDraftEditor.defaultRelativeFrame)
        #expect(e.profile.validate().isEmpty)
        #expect(throws: ProfileDraftError.unknownDesktop(display: "B", number: 5)) { try e.addPlannedWindow(app: safari, onDisplay: "B", desktop: 5) }
    }

    @Test func moveResizeRemoveWindow() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        try e.setRelativeFrame(ofWindow: f.safari1.id, relativeFrame: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), zoneName: "Left")
        var w = e.profile.windows.first { $0.id == f.safari1.id }!
        #expect(w.frame == CGRect(x: 200, y: 280, width: 600, height: 360) && w.zoneName == "Left")
        try e.setFrame(ofWindow: f.safari1.id, frame: CGRect(x: 0, y: 100, width: 1000, height: 900))
        w = e.profile.windows.first { $0.id == f.safari1.id }!
        #expect(w.relativeFrame == CGRect(x: 0, y: 0, width: 0.5, height: 1) && w.zoneName == nil)
        try e.moveWindow(f.safari1.id, toDisplay: "B", desktop: 1)
        w = e.profile.windows.first { $0.id == f.safari1.id }!
        #expect(w.displayUUID == "B" && w.frame == CGRect(x: 2000, y: 0, width: 500, height: 1000))
        try e.removeWindow(f.safari1.id)
        #expect(!e.profile.windows.contains { $0.id == f.safari1.id })
        #expect(throws: ProfileDraftError.unknownWindow(f.safari1.id)) { try e.removeWindow(f.safari1.id) }
        #expect(throws: ProfileDraftError.windowAlreadyFullScreen(f.xcodeFS.id)) { try e.moveWindow(f.xcodeFS.id, toDisplay: "B", desktop: 1) }
        #expect(e.profile.validate().isEmpty)
    }

    @Test func optionsAndLaunchPlan() throws {
        var e = ProfileDraftEditor(Fixture().profile)
        try e.setOptions { $0.addMissingDesktops = true; $0.otherApps = .hide }
        try e.setLaunchPlan(LaunchPlan(mode: .parallel))
        try e.setName("Work")
        #expect(e.profile.options.addMissingDesktops && e.profile.options.otherApps == .hide)
        #expect(e.profile.launchPlan?.mode == .parallel && e.profile.name == "Work")
        #expect(e.profile.validate().isEmpty)
    }

    @Test func failedOperationChangesNothing() throws {
        var e = ProfileDraftEditor(Fixture().profile)
        let before = e.profile
        #expect(throws: ProfileDraftError.self) { try e.setName("   ") }
        #expect(e.profile == before)
    }

    @Test func randomSequenceStaysValid() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        try e.addDesktop(onDisplay: "A", atNumber: 1)
        try e.deleteDesktop(onDisplay: "A", number: 3, moveWindowsTo: 1)
        try e.moveDesktop(onDisplay: "A", number: 1, toNumber: 3)
        try e.makeFullScreen(windowID: f.safari1.id)
        try e.moveFullScreenSpace(onDisplay: "A", position: 5, toIndex: 0)
        try e.removeWindow(f.notesFS.id)
        try e.addDesktop(onDisplay: "B")
        #expect(e.profile.validate().isEmpty)
        #expect(ProfileDraftCheck.errors(ProfileDraftCheck.check(e.profile)).isEmpty)
    }
}

@Suite struct ProfileDraftCheckTests {
    @Test func reportsWarningsAndErrors() throws {
        let f = Fixture()
        var e = ProfileDraftEditor(f.profile)
        try e.addDesktop(onDisplay: "B") // empty Desktop 2 on B
        _ = try e.addPlannedWindow(app: safari, onDisplay: "A", desktop: 1, relativeFrame: f.safari1.relativeFrame)
        _ = try e.addPlannedWindow(app: notes, onDisplay: "A", desktop: 2, relativeFrame: CGRect(x: 0.8, y: 0, width: 0.5, height: 0.5))
        var p = e.profile
        let issues = ProfileDraftCheck.check(p, connectedDisplays: [dispA])
        let codes = Set(issues.map(\.code))
        #expect(codes.contains(.emptyDesktop))
        #expect(codes.contains(.duplicateWindow))
        #expect(codes.contains(.windowOutsideMonitor))
        #expect(codes.contains(.fullScreenAlsoNormalWindow))
        #expect(codes.contains(.missingMonitor))
        #expect(codes.contains(.severalPlannedWindows) == false)
        #expect(!ProfileDraftCheck.blocksSaving(issues))
        #expect(issues.allSatisfy { !$0.message.isEmpty })

        p.windows.append(WindowSnapshot(app: xcode, displayUUID: "A", frame: .zero, relativeFrame: .zero, placement: .desktop(number: 9)))
        let bad = ProfileDraftCheck.check(p)
        #expect(bad.contains { $0.code == .windowOnMissingDesktop && $0.severity == .error })
        #expect(ProfileDraftCheck.blocksSaving(bad))
        #expect(!bad.contains { $0.code == .missingMonitor })
    }

    @Test func cleanProfileHasNoErrors() {
        #expect(ProfileDraftCheck.errors(ProfileDraftCheck.check(Fixture().profile)).isEmpty)
    }

    @Test func severalPlannedWindowsOfOneAppWarn() throws {
        var e = ProfileDraftEditor(Fixture().profile)
        for i in 0..<3 { _ = try e.addPlannedWindow(app: xcode, onDisplay: "A", desktop: 1 + i % 2, relativeFrame: CGRect(x: 0.1 * Double(i), y: 0, width: 0.3, height: 0.3)) }
        let issue = ProfileDraftCheck.check(e.profile).first { $0.code == .severalPlannedWindows }
        #expect(issue?.message.contains("3 windows") == true)
    }
}

@Suite struct EditHistoryTests {
    private final class Clock { var now: TimeInterval = 0 }

    @Test func undoRedoWalkTheStack() {
        let c = Clock()
        var h = EditHistory(initial: 0, clock: { c.now })
        for v in 1...3 { c.now += 10; h.record(v) }
        #expect(h.current == 3 && h.undoCount == 3)
        #expect(h.undo() && h.current == 2)
        #expect(h.undo() && h.current == 1)
        #expect(h.redo() && h.current == 2)
        h.record(9)
        #expect(!h.canRedo && h.current == 9)
        #expect(h.undo() && h.current == 2)
        while h.undo() {}
        #expect(h.current == 0 && !h.canUndo && !h.undo())
        while h.redo() {}
        #expect(h.current == 9 && !h.redo())
    }

    @Test func capDropsOldest() {
        let c = Clock()
        var h = EditHistory(initial: 0, clock: { c.now })
        for v in 1...150 { c.now += 10; h.record(v) }
        #expect(h.undoCount == 100)
        while h.undo() {}
        #expect(h.current == 50)
    }

    @Test func coalescesSameKindWithinHalfSecond() {
        let c = Clock()
        var h = EditHistory(initial: 0, clock: { c.now })
        h.record(1, kind: "nudge")
        c.now += 0.3; h.record(2, kind: "nudge")
        c.now += 0.4; h.record(3, kind: "nudge")   // 0.4 after the previous edit: still inside the window
        #expect(h.undoCount == 1 && h.current == 3)
        c.now += 0.6; h.record(4, kind: "nudge")   // too late: new entry
        #expect(h.undoCount == 2)
        c.now += 0.1; h.record(5, kind: "resize")  // other kind: new entry
        #expect(h.undoCount == 3)
        c.now += 0.1; h.record(6)                  // no kind never coalesces
        c.now += 0.1; h.record(7)
        #expect(h.undoCount == 5)
        h.undo(); h.undo(); h.undo(); h.undo()
        #expect(h.current == 3)
        h.undo()
        #expect(h.current == 0)
    }

    @Test func undoEndsCoalescing() {
        let c = Clock()
        var h = EditHistory(initial: 0, clock: { c.now })
        h.record(1, kind: "k"); c.now += 0.1; h.record(2, kind: "k")
        h.undo()
        c.now += 0.1; h.record(5, kind: "k")
        #expect(h.undoCount == 1 && h.current == 5)
        h.undo()
        #expect(h.current == 0)
    }

    @Test func worksWithProfiles() {
        var h = EditHistory(initial: Fixture().profile)
        var e = ProfileDraftEditor(h.current)
        try? e.addDesktop(onDisplay: "A")
        h.record(e.profile)
        #expect(h.current.spaces.count == 7)
        h.undo()
        #expect(h.current.spaces.count == 6)
    }
}
