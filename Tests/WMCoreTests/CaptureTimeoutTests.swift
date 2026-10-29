import Foundation
import Testing
@testable import WMCore

@Suite struct CaptureTimeoutTests {
    @Test func fastWorkReturnsItsValue() async {
        let value = await CaptureTimeout.race(limit: .seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func hungWorkTimesOutWithNil() async {
        let start = ContinuousClock.now
        let value: Int? = await CaptureTimeout.race(limit: .milliseconds(100)) {
            try? await Task.sleep(for: .seconds(30))
            return 1
        }
        #expect(value == nil)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func messageIsVisibleText() {
        #expect(CaptureTimeout.message.contains("too long"))
        #expect(CaptureTimeout.defaultLimit == .seconds(15))
    }
}
