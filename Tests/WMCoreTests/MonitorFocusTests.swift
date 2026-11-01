import Testing
@testable import WMCore

@Suite struct MonitorFocusTests {
    @Test func keepsFocusedMonitor() { #expect(MonitorFocus.resolve(focused: "b", ids: ["a", "b"]) == "b") }
    @Test func fallsBackToFirstWhenFocusGone() { #expect(MonitorFocus.resolve(focused: "x", ids: ["a", "b"]) == "a") }
    @Test func nilFocusUsesFirst() { #expect(MonitorFocus.resolve(focused: nil, ids: ["a"]) == "a") }
    @Test func noMonitorsIsNil() { #expect(MonitorFocus.resolve(focused: "a", ids: []) == nil) }
}
