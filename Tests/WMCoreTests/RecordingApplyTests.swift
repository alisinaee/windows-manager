import CoreGraphics
import Foundation
import Testing
@testable import WMCore

private let dispA = DisplayIdentity(uuid: "A", name: "Studio", frame: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                                    visibleFrame: CGRect(x: 0, y: 100, width: 2000, height: 900), isMain: true, isBuiltIn: false)
private let dispB = DisplayIdentity(uuid: "B", name: "Dell", frame: CGRect(x: 2000, y: 0, width: 1000, height: 1000),
                                    visibleFrame: CGRect(x: 2000, y: 0, width: 1000, height: 1000), isMain: false, isBuiltIn: false)
private let safari = AppRef(bundleID: "com.apple.Safari", name: "Safari")
private let mail = AppRef(bundleID: "com.apple.mail", name: "Mail")

private func win(_ app: AppRef, display: String, _ placement: SpacePlacement, minimized: Bool = false) -> WindowSnapshot {
    let r = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
    return WindowSnapshot(app: app, displayUUID: display, frame: CGRect(x: 100, y: 100, width: 500, height: 400),
                          relativeFrame: r, placement: placement, isMinimized: minimized)
}

private func base() -> Profile {
    DraftSession.blankProfile(displays: [dispA])
}

@Test func recordingAddsMissingMonitorAndDesktops() throws {
    var editor = ProfileDraftEditor(base())
    let result = try editor.mergeRecording(windows: [win(safari, display: "B", .desktop(number: 3)),
                                                     win(mail, display: "A", .desktop(number: 2))],
                                           displays: [dispA, dispB])
    #expect(result.added == 2)
    #expect(result.skipped.isEmpty)
    let p = editor.profile
    #expect(p.displays.map(\.uuid) == ["A", "B"])
    #expect(p.spaces.filter { $0.displayUUID == "B" && $0.kind == .desktop }.count == 3)
    #expect(p.spaces.filter { $0.displayUUID == "A" && $0.kind == .desktop }.count == 2)
    #expect(p.windows.count == 2)
    #expect(p.validate().isEmpty)
    #expect(p.monitorSetKey == DisplayMap.monitorSetKey([dispA, dispB]))
}

@Test func recordingSkipsFullScreenMinimizedAndAllDesktopsWithNames() throws {
    var editor = ProfileDraftEditor(base())
    let result = try editor.mergeRecording(windows: [win(safari, display: "A", .fullScreen(position: 1)),
                                                     win(mail, display: "A", .desktop(number: 1), minimized: true),
                                                     win(safari, display: "A", .allDesktops),
                                                     win(mail, display: "A", .desktop(number: 1))],
                                           displays: [dispA])
    #expect(result.added == 1)
    #expect(result.skipped == ["Safari (full screen)", "Mail (minimized)", "Safari (all Desktops)"])
    #expect(result.note == "Skipped Safari (full screen), Mail (minimized), Safari (all Desktops)")
    #expect(editor.profile.windows.count == 1)
}

@Test func recordingSkipsWindowOnUnknownMonitor() throws {
    var editor = ProfileDraftEditor(base())
    let result = try editor.mergeRecording(windows: [win(safari, display: "Z", .desktop(number: 1))], displays: [dispA])
    #expect(result.added == 0)
    #expect(result.skipped == ["Safari (monitor not connected)"])
}
