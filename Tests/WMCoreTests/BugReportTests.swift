import XCTest
@testable import WMCore

final class BugReportTests: XCTestCase {
    let r = BugRedactor(home: "/Users/jane", userName: "jane", hostNames: ["janes-mbp", "janes-mbp.local"])

    func testRedactsHomeUserEmailHost() {
        let out = r.redact("open /Users/jane/Documents/x.json by jane@example.com on janes-mbp.local user jane")
        XCTAssertFalse(out.contains("jane"))
        XCTAssertTrue(out.contains("~/Documents/x.json"))
        XCTAssertTrue(out.contains("<email>"))
        XCTAssertTrue(out.contains("<host>"))
    }

    func testWindowTitlesRedactedAppNamesKept() {
        let out = r.redact(#"restore Safari window "Secret bank - Safari" moved"#)
        XCTAssertEqual(out, #"restore Safari window "<title>" moved"#)
    }

    func testTail() {
        let text = (1...500).map(String.init).joined(separator: "\n") + "\n"
        let t = BugReport.tail(text)
        XCTAssertEqual(t.count, 300)
        XCTAssertEqual(t.last, "500")
    }

    func input(logs: Int = 3) -> BugReportInput {
        BugReportInput(title: "Crash", description: "It broke for jane", environment: BugReportEnvironment(appVersion: "1.2", appBuild: "9", displayCount: 2, stageManager: false),
                       logLines: (1...logs).map { "line \($0) /Users/jane/x " + String(repeating: "a", count: 40) })
    }

    func testBodySections() {
        let b = BugReport.body(input(), redactor: r)
        for s in ["### What happened", "### Expected", "### Steps", "### Environment", "<details>"] { XCTAssertTrue(b.contains(s), s) }
        XCTAssertFalse(b.contains("jane"))
        XCTAssertTrue(b.contains("- App: 1.2 (build 9)"))
    }

    func testNoLogsWhenUnticked() {
        var i = input(); i.includeLogs = false
        XCTAssertFalse(BugReport.body(i, redactor: r).contains("<details>"))
    }

    func testIssueLinkSmall() {
        let l = BugReport.issueLink(input(), redactor: r)
        XCTAssertFalse(l.truncated)
        let s = l.url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://github.com/alisinaee/windows-manager/issues/new?template=bug_report.yml&title=Crash&body="))
        XCTAssertFalse(s.contains(" "))
    }

    func testIssueLinkTruncatesLongBody() {
        let l = BugReport.issueLink(input(logs: 300), redactor: r)
        XCTAssertTrue(l.truncated)
        let comp = BugReport.body(input(logs: 300), redactor: r, compact: true)
        XCTAssertTrue(comp.contains("line 300"))
        XCTAssertFalse(comp.contains("line 200 "))
        XCTAssertFalse(comp.contains("### What happened"))
        XCTAssertLessThanOrEqual(BugReport.encode(comp).count, 6500)
    }
}
