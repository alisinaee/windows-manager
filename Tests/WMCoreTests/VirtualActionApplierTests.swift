import XCTest
import CoreGraphics
@testable import WMCore

private final class FakeSystem: WorkspaceSystem {
    var frames: [UInt32: CGRect] = [:]
    var unhideOK = true
    var unhidden: [Int32] = []
    func liveWindows() -> [VirtualLiveWindow] { [] }
    func bundleID(ofPID pid: Int32) -> String? { nil }
    func hideApp(pid: Int32) -> Bool { true }
    func unhideApp(pid: Int32) -> Bool { if unhideOK { unhidden.append(pid) }; return unhideOK }
    func frame(ofWindow windowID: UInt32, pid: Int32) -> CGRect? { frames[windowID] }
    func setPosition(_ origin: CGPoint, ofWindow windowID: UInt32, pid: Int32) -> Bool {
        guard var f = frames[windowID] else { return false }
        f.origin = origin; frames[windowID] = f; return true
    }
    func setFrame(_ frame: CGRect, ofWindow windowID: UInt32, pid: Int32) -> Bool {
        guard frames[windowID] != nil else { return false }
        frames[windowID] = frame; return true
    }
    func screenFrames() -> [CGRect] { [] }
}

final class VirtualActionApplierTests: XCTestCase {
    func testAppliesUnhideAndRestoreAndSkipsHides() {
        let system = FakeSystem()
        system.frames[7] = CGRect(x: 5000, y: 0, width: 100, height: 100)
        let target = CGRect(x: 10, y: 20, width: 100, height: 100)
        let report = VirtualActionApplier.apply([
            .unhideApp(pid: 3), .restoreFrame(windowID: 7, pid: 3, frame: target), .hideWindow(windowID: 9, pid: 4),
        ], system: system)
        XCTAssertEqual(report.unhiddenApps, [3])
        XCTAssertEqual(report.restoredWindows, [7])
        XCTAssertEqual(report.skippedHides, 1)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(system.frames[7], target)
    }

    func testReportsFailures() {
        let system = FakeSystem()
        system.unhideOK = false
        let report = VirtualActionApplier.apply([
            .unhideApp(pid: 3), .restoreFrame(windowID: 8, pid: 3, frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
        ], system: system)
        XCTAssertEqual(report.failures.count, 2)
    }
}
