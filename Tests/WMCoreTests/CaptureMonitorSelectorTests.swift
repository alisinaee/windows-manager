import CoreGraphics
import Foundation
import Testing
@testable import WMCore

private let monA = DisplayIdentity(uuid: "AAAA-1111", name: "Studio Display", frame: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                                   visibleFrame: CGRect(x: 0, y: 0, width: 2000, height: 1000), isMain: true, isBuiltIn: false)
private let monB = DisplayIdentity(uuid: "BBBB-2222", name: "Dell U2720Q", frame: CGRect(x: 2000, y: 0, width: 1000, height: 1000),
                                   visibleFrame: CGRect(x: 2000, y: 0, width: 1000, height: 1000), isMain: false, isBuiltIn: false)
private let appSafari = AppRef(bundleID: "com.apple.Safari", name: "Safari")
private let appMail = AppRef(bundleID: "com.apple.mail", name: "Mail")

private func snap(_ app: AppRef, _ display: String, minimized: Bool = false) -> WindowSnapshot {
    WindowSnapshot(app: app, displayUUID: display, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                   relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), placement: .desktop(number: 1),
                   isFullScreen: false, isMinimized: minimized)
}

/// Monitor A (index 1): Safari and Mail on Desktop 1, plus a minimized Mail. Monitor B (index 2): Safari on Desktop 1.
private struct MonitorFixture {
    let aSafari = snap(appSafari, "AAAA-1111")
    let aMail = snap(appMail, "AAAA-1111")
    let aMailMin = snap(appMail, "AAAA-1111", minimized: true)
    let bSafari = snap(appSafari, "BBBB-2222")
    let profile: Profile

    init() {
        let spaces = [
            SpaceSnapshot(displayUUID: "AAAA-1111", position: 0, kind: .desktop, desktopNumber: 1),
            SpaceSnapshot(displayUUID: "BBBB-2222", position: 0, kind: .desktop, desktopNumber: 1),
        ]
        profile = Profile(name: "P", monitorSetKey: "k", displays: [monA, monB], spaces: spaces,
                          windows: [aSafari, aMail, aMailMin, bSafari])
    }

    var monitorAIDs: Set<UUID> { [aSafari.id, aMail.id, aMailMin.id] }
}

@Suite struct CaptureMonitorSelectorTests {
    @Test func uuidSelectsAllWindowsOnThatMonitorIgnoringCase() {
        let f = MonitorFixture()
        #expect(CLICaptureFilter.windowIDs(in: f.profile, selectors: ["monitor:AAAA-1111"]) == f.monitorAIDs)
        #expect(CLICaptureFilter.windowIDs(in: f.profile, selectors: ["monitor:bbbb-2222"]) == [f.bSafari.id])
    }

    @Test func nameContainsIgnoringCase() {
        let f = MonitorFixture()
        #expect(CLICaptureFilter.windowIDs(in: f.profile, selectors: ["monitor:dell"]) == [f.bSafari.id])
        #expect(CLICaptureFilter.windowIDs(in: f.profile, selectors: ["monitor:STUDIO display"]) == f.monitorAIDs)
    }

    @Test func oneBasedIndex() {
        let f = MonitorFixture()
        #expect(CLICaptureFilter.windowIDs(in: f.profile, selectors: ["monitor:1"]) == f.monitorAIDs)
        #expect(CLICaptureFilter.windowIDs(in: f.profile, selectors: ["monitor:2"]) == [f.bSafari.id])
        #expect(CLICaptureFilter.windowIDs(in: f.profile, selectors: ["monitor:0"]).isEmpty)
    }

    @Test func combinesWithOtherSelectorsAsUnion() {
        let f = MonitorFixture()
        let picked = CLICaptureFilter.windowIDs(in: f.profile, selectors: ["monitor:dell", "app:mail"])
        #expect(picked == [f.bSafari.id, f.aMail.id, f.aMailMin.id])
        #expect(CLICaptureFilter.windowIDs(in: f.profile, selectors: ["monitor:1", "monitor:2"]).count == 4)
    }

    @Test func unknownMonitorIsUsageErrorWithAvailableList() throws {
        let f = MonitorFixture()
        do {
            try CLICaptureFilter.validateMonitors(in: f.profile, selectors: ["monitor:Projector"])
            Issue.record("expected a usage error")
        } catch let failure as CLIFailure {
            #expect(failure.exit == .usage)
            #expect(failure.exit.rawValue == 2)
            let hint = failure.hint ?? ""
            #expect(hint.contains("1 Studio Display (AAAA-1111)"))
            #expect(hint.contains("2 Dell U2720Q (BBBB-2222)"))
        }
    }

    @Test func outOfRangeIndexAndAmbiguousNameAreRejected() {
        let f = MonitorFixture()
        #expect(throws: CLIFailure.self) {
            try CLICaptureFilter.validateMonitors(in: f.profile, selectors: ["monitor:3"])
        }
        // "l" is part of both names ("Studio Display", "Dell U2720Q"), so the selector is ambiguous.
        #expect(throws: CLIFailure.self) {
            try CLICaptureFilter.validateMonitors(in: f.profile, selectors: ["monitor:l"])
        }
        #expect(throws: CLIFailure.self) {
            try CLICaptureFilter.validateMonitors(in: f.profile, selectors: ["monitor:"])
        }
    }

    @Test func knownMonitorsPassValidation() throws {
        let f = MonitorFixture()
        try CLICaptureFilter.validateMonitors(in: f.profile, selectors: ["monitor:1", "app:safari", "fullscreen"])
    }
}
