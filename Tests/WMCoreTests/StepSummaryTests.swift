import Foundation
import Testing
@testable import WMCore

@Suite struct StepSummaryTests {
    @Test func symbolsPerKind() {
        let loc = ElementLocator(bundleID: "com.google.Chrome", path: [ElementMatcher(role: "AXButton", title: "Who's using Chrome?")])
        #expect(StepSummary.of(.launchApp(bundleID: "com.google.Chrome")).symbol == "app.badge")
        #expect(StepSummary.of(.press(locator: loc)).symbol == "cursorarrow.click")
        #expect(StepSummary.of(.menu(bundleID: "a.B", path: ["File"])).symbol == "filemenu.and.selection")
        #expect(StepSummary.of(.typeText(text: "x")).symbol == "character.cursor.ibeam")
        #expect(StepSummary.of(.key(combo: "cmd+t")).symbol == "keyboard")
        #expect(StepSummary.of(.shell(command: "ls")).symbol == "terminal")
        #expect(StepSummary.of(.terminalCommand(command: "ls")).symbol == "terminal")
        #expect(StepSummary.of(.openURL(url: "https://a.b")).symbol == "link")
        #expect(StepSummary.of(.runShortcut(name: "S")).symbol == "square.stack.3d.up")
        #expect(StepSummary.of(.waitFor(locator: loc)).symbol == "hourglass")
        #expect(StepSummary.of(.delay(seconds: 1)).symbol == "timer")
    }

    @Test func summaries() {
        let loc = ElementLocator(bundleID: "com.google.Chrome", path: [ElementMatcher(role: "AXButton", title: "Who's using Chrome?")])
        #expect(StepSummary.of(.press(locator: loc)).summary == "Press · Chrome › Who's using Chrome?")
        #expect(StepSummary.of(.terminalCommand(command: "fortiChromeMain")).summary == "Run in Terminal · fortiChromeMain")
        #expect(StepSummary.of(.delay(seconds: 1.5)).summary == "Wait 1.5 s")
        #expect(StepSummary.of(.delay(seconds: 2)).summary == "Wait 2 s")
    }

    @Test func optionalUsesInnerStep() {
        let s = StepSummary.of(.optional(step: .key(combo: "cmd+t")))
        #expect(s.symbol == "keyboard")
        #expect(s.summary == "Keys · cmd+t")
    }

    @Test func longTextIsClipped() {
        let s = StepSummary.of(.shell(command: String(repeating: "a", count: 200)))
        #expect(s.summary.count < 80)
    }
}
