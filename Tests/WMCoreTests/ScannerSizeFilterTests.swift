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

    private func catalog(_ id: UInt32, pid: Int32, app: String = "TextEdit", _ w: CGFloat, _ h: CGFloat,
                         spaces: [UInt64] = [5]) -> CatalogWindow {
        CatalogWindow(windowID: id, pid: pid, appName: app, title: nil,
                      bounds: CGRect(x: 0, y: 0, width: w, height: h), alpha: 1, isOnScreen: false, spaceIDs: spaces)
    }

    /// Small windows on a Space with no AX frame are the ones to look up with AXRemoteWindows, grouped by pid.
    func testWindowsNeedingFrameAreSmallOnSpaceWithoutFrame() {
        let all = [
            catalog(7, pid: 1, 73, 101),                              // thumbnail, no frame: wanted
            catalog(8, pid: 1, 73, 101),                              // thumbnail with a frame: not wanted
            catalog(9, pid: 1, 603, 505),                             // normal size: not wanted
            catalog(10, pid: 1, 36, 35, spaces: []),                  // on no Space: not wanted
            catalog(11, pid: 2, 73, 101),                             // other pid, not a candidate
            catalog(12, pid: 1, 36, 35),                              // tiny helper on a Space, no frame: wanted
        ]
        let ax: [UInt32: AXWindowDetails] = [
            8: AXWindowDetails(title: nil, documentPath: nil, isMinimized: false,
                               frame: CGRect(x: 0, y: 0, width: 603, height: 505)),
        ]
        let wanted = WorkspaceScanner.thumbnailWindowsNeedingFrame(catalog: all, ax: ax, pids: [1])
        XCTAssertEqual(wanted, [1: [7, 12]])
    }

    /// A dropped thumbnail: small, on a Space, known and not excluded app, and no frame that makes it a user window.
    func testUnresolvedThumbnailPredicate() {
        let textEdit = AppRef(bundleID: "com.apple.TextEdit", name: "TextEdit", path: nil)
        let dock = AppRef(bundleID: "com.apple.dock", name: "Dock", path: nil)
        let thumb = catalog(7, pid: 1, 73, 101)
        let big = CGRect(x: 0, y: 0, width: 603, height: 505)
        XCTAssertTrue(WorkspaceScanner.isUnresolvedThumbnail(thumb, app: textEdit, ax: [:], options: ScanOptions()))
        XCTAssertFalse(WorkspaceScanner.isUnresolvedThumbnail(thumb, app: nil, ax: [:], options: ScanOptions()))
        XCTAssertFalse(WorkspaceScanner.isUnresolvedThumbnail(thumb, app: dock, ax: [:], options: ScanOptions()))
        XCTAssertFalse(WorkspaceScanner.isUnresolvedThumbnail(
            thumb, app: textEdit, ax: [7: AXWindowDetails(title: nil, documentPath: nil, isMinimized: nil, frame: big)],
            options: ScanOptions()))
        XCTAssertFalse(WorkspaceScanner.isUnresolvedThumbnail(
            catalog(8, pid: 1, 603, 505), app: textEdit, ax: [:], options: ScanOptions()))
    }

    func testUnresolvedThumbnailNotesGroupByApp() {
        XCTAssertEqual(WorkspaceScanner.unresolvedThumbnailNotes(appNames: ["TextEdit", "Arc", "TextEdit"]), [
            "2 windows of TextEdit on other Spaces could not be read and were skipped",
            "1 window of Arc on other Spaces could not be read and were skipped",
        ])
        XCTAssertEqual(WorkspaceScanner.unresolvedThumbnailNotes(appNames: []), [])
    }

    /// Full assemble: a thumbnail without frame is dropped and reported; with a frame it is kept and not reported.
    func testAssembleReportsDroppedThumbnail() {
        let display = DisplayIdentity(uuid: "D1", name: "Main", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), isMain: true,
                                      isBuiltIn: false)
        let skyLight = [DisplaySpaces(displayIdentifier: "D1", displayName: "Main", currentSpaceID: 1, spaces: [
            SpaceInfo(id: 1, uuid: "S1", kind: .desktop, index: 0, isCurrent: true, fullScreenOwnerPID: nil,
                      fullScreenWindowIDs: [], ownerAppNames: []),
            SpaceInfo(id: 5, uuid: "S5", kind: .desktop, index: 1, isCurrent: false, fullScreenOwnerPID: nil,
                      fullScreenWindowIDs: [], ownerAppNames: []),
        ])]
        let textEdit = AppRef(bundleID: "com.apple.TextEdit", name: "TextEdit", path: nil)
        let windows = [catalog(7, pid: 1, 73, 101)]
        let dropped = WorkspaceScanner.assemble(displays: [display], skyLight: skyLight, catalog: windows,
                                                activeSpaceID: 1, appRef: { _ in textEdit }, ax: [:])
        XCTAssertTrue(dropped.windows.isEmpty)
        XCTAssertEqual(dropped.notes, ["1 window of TextEdit on other Spaces could not be read and were skipped"])

        let frame = AXWindowDetails(title: nil, documentPath: nil, isMinimized: false,
                                    frame: CGRect(x: 0, y: 0, width: 603, height: 505))
        let kept = WorkspaceScanner.assemble(displays: [display], skyLight: skyLight, catalog: windows,
                                             activeSpaceID: 1, appRef: { _ in textEdit }, ax: [7: frame])
        XCTAssertEqual(kept.windows.map(\.windowID), [7])
        XCTAssertTrue(kept.notes.isEmpty)
    }
}
