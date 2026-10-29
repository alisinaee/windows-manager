import ApplicationServices
import Foundation
import Testing
@testable import WMCore

@Suite struct ReviewFixesTests {
    @MainActor @Test func slowOlderLoadDoesNotOverwriteNewer() async {
        let latest = LatestOnly<Int>()
        var applied: [Int] = []
        let slow = latest.load({ try? await Task.sleep(for: .milliseconds(300)); return 1 }, apply: { applied.append($0) })
        let fast = latest.load({ 2 }, apply: { applied.append($0) })
        await slow.value; await fast.value
        #expect(applied == [2])
    }

    @Test func hungSelectiveScanFailsWithMessage() async {
        let scan = await CaptureTimeout.race(limit: .milliseconds(50)) { () async -> Int in
            try? await Task.sleep(for: .seconds(5)); return 1
        }
        #expect(scan == nil)
        #expect(SelectiveCaptureScan.outcome(scan) == .failure(CaptureTimeoutFailure(message: CaptureTimeout.message)))
        #expect(SelectiveCaptureScan.outcome(7) == .success(7))
    }

    @Test func unsupportedRaiseIsFailureWithoutStageManager() {
        for e in [AXError.actionUnsupported, .attributeUnsupported] {
            #expect(RaiseOutcome.result(for: e, stageManagerOn: false) == .failure("the window did not accept AXRaise (AXError \(e.rawValue))"))
            #expect(RaiseOutcome.result(for: e, stageManagerOn: true).skippedReason != nil)
        }
    }

    @Test func lateFetchCallbackIsIgnored() throws {
        var late: ((Data?, URLResponse?, Error?) -> Void)?
        #expect(throws: (any Error).self) {
            _ = try UpdateCheck.fetchSync(URL(string: "https://x.test")!, wait: 0.05) { _, done in late = done }
        }
        late?(Data("x".utf8), nil, nil) // must not crash or change anything
    }

    @Test func fetchReturnsData() throws {
        let d = try UpdateCheck.fetchSync(URL(string: "https://x.test")!, wait: 2) { _, done in
            let ok = HTTPURLResponse(url: URL(string: "https://x.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)
            done(Data("hi".utf8), ok, nil)
        }
        #expect(d == Data("hi".utf8))
    }
}
