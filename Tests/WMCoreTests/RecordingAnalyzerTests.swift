import Foundation
import Testing
@testable import WMCore

private func press(_ app: String, _ title: String, subrole: String? = nil, role: String = "AXButton") -> ActionStep {
    .press(locator: ElementLocator(bundleID: app, path: [ElementMatcher(role: role, subrole: subrole, title: title)]))
}
private func t(_ step: ActionStep, _ time: TimeInterval) -> TimedStep { TimedStep(step: step, time: time) }

@Suite struct RecordingAnalyzerTests {
    private let names = ["app.streisand": "Streisand", "app.term": "Terminal"]

    @Test func groupsByAppAndNamesActions() {
        let rec = [
            t(.launchApp(bundleID: "app.streisand"), 0), t(press("app.streisand", "Connected"), 1),
            t(.launchApp(bundleID: "app.term"), 2), t(.typeText(text: "ls"), 3), t(.key(combo: "return"), 4),
        ]
        let a = RecordingAnalyzer.analyze(rec, windowBundleIDs: [], appNames: names)
        #expect(a.layoutBundleIDs.isEmpty)
        #expect(a.actions.map(\.name) == ["Streisand: press Connected", "Terminal: type command"])
        #expect(a.actions[0].steps.count == 2)
        #expect(a.actions[1].steps.count == 3)
    }

    @Test func launchAppDroppedForWindowAppsOnly() {
        let rec = [
            t(.launchApp(bundleID: "app.streisand"), 0), t(press("app.streisand", "Connected"), 1),
            t(.launchApp(bundleID: "app.menubar"), 2), t(press("app.menubar", "Go"), 3),
        ]
        let a = RecordingAnalyzer.analyze(rec, windowBundleIDs: ["app.streisand"], appNames: names)
        #expect(a.layoutBundleIDs == ["app.streisand"])
        #expect(a.actions[0].steps.map(\.step) == [press("app.streisand", "Connected")])
        #expect(a.actions[1].steps.first?.step == .launchApp(bundleID: "app.menubar"))
        #expect(a.actions[1].name == "menubar: press Go")
    }

    @Test func windowChromeClicksDropped() {
        let rec = [
            t(.launchApp(bundleID: "app.term"), 0),
            t(press("app.term", "close", subrole: "AXCloseButton"), 1),
            t(press("app.term", "zoom", subrole: "AXZoomButton"), 2),
            t(press("app.term", "", role: "AXToolbar"), 3),
            t(press("app.term", "OK"), 4),
        ]
        let a = RecordingAnalyzer.analyze(rec, windowBundleIDs: ["app.term"], appNames: names)
        #expect(a.actions.count == 1)
        #expect(a.actions[0].steps.map(\.step) == [press("app.term", "OK")])
    }

    @Test func chromeOnlyRecordingGivesNoActions() {
        let rec = [t(.launchApp(bundleID: "app.term"), 0), t(press("app.term", "x", subrole: "AXCloseButton"), 1)]
        let a = RecordingAnalyzer.analyze(rec, windowBundleIDs: ["app.term"])
        #expect(a.layoutBundleIDs == ["app.term"] && a.actions.isEmpty)
    }

    @Test func appSwitchBackStartsNewGroup() {
        let rec = [t(press("a", "1"), 0), t(press("b", "2"), 1), t(press("a", "3"), 2), t(.key(combo: "tab"), 3)]
        let a = RecordingAnalyzer.analyze(rec, windowBundleIDs: [])
        #expect(a.actions.map { $0.steps.count } == [1, 1, 2])
    }

    @Test func timingBecomesRoundedCappedDelays() {
        let rec = [t(press("a", "1"), 0), t(press("a", "2"), 0.9), t(press("a", "3"), 3.2), t(press("a", "4"), 30)]
        let action = RecordingAnalyzer.analyze(rec, windowBundleIDs: []).actions[0]
        #expect(action.resolvedSteps(keepTiming: false).count == 4)
        let steps = action.resolvedSteps(keepTiming: true)
        #expect(steps == [press("a", "1"), press("a", "2"), .delay(seconds: 2.5), press("a", "3"),
                          .delay(seconds: 10), press("a", "4")])
        #expect(action.profileAction(keepTiming: true).steps.count == 6)
    }

    @Test func pauseRules() {
        #expect(RecordingAnalyzer.pause(from: 0, to: 1) == nil)
        #expect(RecordingAnalyzer.pause(from: 0, to: 1.3) == 1.5)
    }
}
