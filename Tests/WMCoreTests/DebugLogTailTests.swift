import XCTest
@testable import WMCore

final class DebugLogTailTests: XCTestCase {
    func testAppendKeepsNewestAndSkipsBlank() {
        var lines: [String] = []
        for i in 0..<5 { lines = DebugLogTail.append("l\(i)", to: lines, limit: 3) }
        XCTAssertEqual(lines, ["l2", "l3", "l4"])
        XCTAssertEqual(DebugLogTail.append("  \n", to: lines, limit: 3), lines)
    }
}
