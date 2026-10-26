import CoreGraphics
import XCTest
@testable import WMCore

final class ScannerSizeFilterTests: XCTestCase {
    private func window(_ w: CGFloat, _ h: CGFloat, spaces: [UInt64] = [5]) -> CatalogWindow {
        CatalogWindow(windowID: 7, pid: 1, appName: "TextEdit", title: nil,
                      bounds: CGRect(x: 0, y: 0, width: w, height: h), alpha: 1, isOnScreen: false, spaceIDs: spaces)
    }

    func testNormalWindowKept() {
        XCTAssertTrue(WorkspaceScanner.isUserWindow(window(603, 505), bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(WorkspaceScanner.usesAccessibilityFrame(window(603, 505), axFrame: nil))
    }

    func testThumbnailBoundsWithLargeAXFrameKept() {
        let ax = CGRect(x: 100, y: 100, width: 603, height: 505)
        let thumb = window(73, 101)
        XCTAssertFalse(WorkspaceScanner.isUserWindow(thumb, bundleID: "com.apple.TextEdit"))
        XCTAssertTrue(WorkspaceScanner.isUserWindow(thumb, bundleID: "com.apple.TextEdit", axFrame: ax))
        XCTAssertTrue(WorkspaceScanner.usesAccessibilityFrame(thumb, axFrame: ax))
        XCTAssertTrue(WorkspaceScanner.isUserWindow(window(36, 35), bundleID: "com.apple.TextEdit", axFrame: ax))
    }

    func testTinyHelperStaysOut() {
        let tiny = window(36, 35)
        XCTAssertFalse(WorkspaceScanner.isUserWindow(tiny, bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(WorkspaceScanner.isUserWindow(tiny, bundleID: "com.apple.TextEdit",
                                                     axFrame: CGRect(x: 0, y: 0, width: 20, height: 20)))
        XCTAssertFalse(WorkspaceScanner.isUserWindow(window(36, 35, spaces: []), bundleID: "com.apple.TextEdit",
                                                     axFrame: CGRect(x: 0, y: 0, width: 600, height: 400)))
    }
}
