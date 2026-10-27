import CoreGraphics
import XCTest
@testable import WMCore

/// P6.63: the current Space comes from the windows on screen, and a Stage Manager strip thumbnail is judged by its
/// window-server bounds against the Accessibility frame (the frame itself stays the real one).
final class ScannerCurrentSpaceTests: XCTestCase {
    private let display = DisplayIdentity(uuid: "D1", name: "Main", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                          visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), isMain: true,
                                          isBuiltIn: false)
    private let textEdit = AppRef(bundleID: "com.apple.TextEdit", name: "TextEdit", path: nil)
    private let axFrame = CGRect(x: 300, y: 200, width: 877, height: 499)

    /// Desktop 1 (id 1) and Desktop 5 (id 5), and a full-screen Space (id 9) that SkyLight names as current.
    private func skyLight(current: UInt64 = 9) -> [DisplaySpaces] {
        [DisplaySpaces(displayIdentifier: "D1", displayName: "Main", currentSpaceID: current, spaces: [
            SpaceInfo(id: 1, uuid: "S1", kind: .desktop, index: 0, isCurrent: false, fullScreenOwnerPID: nil,
                      fullScreenWindowIDs: [], ownerAppNames: []),
            SpaceInfo(id: 5, uuid: "S5", kind: .desktop, index: 1, isCurrent: false, fullScreenOwnerPID: nil,
                      fullScreenWindowIDs: [], ownerAppNames: []),
            SpaceInfo(id: 9, uuid: "S9", kind: .fullscreen, index: 2, isCurrent: true, fullScreenOwnerPID: 2,
                      fullScreenWindowIDs: [], ownerAppNames: ["Arc"]),
        ])]
    }

    private func window(_ id: UInt32, bounds: CGRect, onScreen: Bool, spaces: [UInt64] = [1], pid: Int32 = 1,
                        app: String = "TextEdit") -> CatalogWindow {
        CatalogWindow(windowID: id, pid: pid, appName: app, title: nil, bounds: bounds, alpha: 1,
                      isOnScreen: onScreen, spaceIDs: spaces)
    }

    private func assemble(_ catalog: [CatalogWindow], ax: [UInt32: AXWindowDetails], stageManagerOn: Bool = false,
                          app: AppRef? = nil, current: UInt64 = 9) -> WorkspaceScan {
        WorkspaceScanner.assemble(displays: [display], skyLight: skyLight(current: current), catalog: catalog,
                                  activeSpaceID: current, appRef: { _ in app ?? self.textEdit }, ax: ax,
                                  stageManagerOn: stageManagerOn)
    }

    private func details(_ frame: CGRect?) -> AXWindowDetails {
        AXWindowDetails(title: nil, documentPath: nil, isMinimized: false, frame: frame)
    }

    // MARK: (a) current Space from the windows on screen

    /// SkyLight says the full-screen Space is current, but the window on Desktop 1 is on screen: Desktop 1 is current.
    func testWindowOnScreenOnDesktopMakesThatDesktopCurrent() {
        let catalog = [window(7, bounds: axFrame, onScreen: true, spaces: [1])]
        let scan = assemble(catalog, ax: [7: details(axFrame)])
        XCTAssertEqual(scan.windows.map(\.windowID), [7])
        XCTAssertTrue(scan.windows[0].isOnCurrentSpace)
    }

    /// Nothing on screen on the monitor: SkyLight's answer stands, so the Desktop window is not on the current Space.
    func testSkyLightUsedWhenNothingIsOnScreen() {
        let catalog = [window(7, bounds: axFrame, onScreen: false, spaces: [1])]
        let scan = assemble(catalog, ax: [7: details(axFrame)])
        XCTAssertEqual(scan.windows.map(\.windowID), [7])
        XCTAssertFalse(scan.windows[0].isOnCurrentSpace)
    }

    func testMostVotedOnScreenSpaceWins() {
        let scanned = skyLight().map { list in
            ScannedSpaces(displayUUID: "D1", skyLightIdentifier: list.displayIdentifier, currentSpaceID: list.currentSpaceID,
                          spaces: list.spaces)
        }
        let catalog = [
            window(1, bounds: axFrame, onScreen: true, spaces: [5]),
            window(2, bounds: axFrame, onScreen: true, spaces: [5]),
            window(3, bounds: axFrame, onScreen: true, spaces: [1]),
            window(4, bounds: axFrame, onScreen: true, spaces: [1, 5]),  // on all Desktops: does not vote
        ]
        XCTAssertEqual(WorkspaceScanner.currentSpaces(scanned: scanned, windows: catalog), [5])
    }

    // MARK: (b) and (c) Stage Manager strip thumbnail

    /// The window server draws the strip thumbnail at 118x97 while Accessibility has the real 877x499 frame.
    func testStripThumbnailKeepsAccessibilityFrame() {
        let thumb = window(7, bounds: CGRect(x: 0, y: 0, width: 118, height: 97), onScreen: true)
        XCTAssertTrue(WorkspaceScanner.isStripThumbnail(serverBounds: thumb.bounds, isOnScreen: true, axFrame: axFrame,
                                                        stageManagerOn: true, isOwnWindow: false))
        let scan = assemble([thumb], ax: [7: details(axFrame)], stageManagerOn: true)
        XCTAssertEqual(scan.windows.count, 1)
        XCTAssertEqual(scan.windows[0].isStripThumbnail, true)
        XCTAssertEqual(scan.windows[0].frame, axFrame)
        XCTAssertEqual(scan.windows[0].serverBounds, thumb.bounds)
    }

    /// The same sizes with Stage Manager off: the window is a normal window, not a thumbnail.
    func testSameSizesWithStageManagerOffAreNotThumbnails() {
        let thumb = window(7, bounds: CGRect(x: 0, y: 0, width: 118, height: 97), onScreen: true)
        XCTAssertFalse(WorkspaceScanner.isStripThumbnail(serverBounds: thumb.bounds, isOnScreen: true, axFrame: axFrame,
                                                         stageManagerOn: false, isOwnWindow: false))
        let scan = assemble([thumb], ax: [7: details(axFrame)], stageManagerOn: false)
        XCTAssertEqual(scan.windows.map(\.isStripThumbnail), [false])
        XCTAssertEqual(scan.windows.first?.serverBounds, thumb.bounds)
    }

    /// Off screen, no Accessibility frame, or bounds that are not under a quarter of the frame: not a thumbnail.
    func testThumbnailRuleNeedsOnScreenFrameAndSmallShare() {
        let small = CGRect(x: 0, y: 0, width: 118, height: 97)
        XCTAssertFalse(WorkspaceScanner.isStripThumbnail(serverBounds: small, isOnScreen: false, axFrame: axFrame,
                                                         stageManagerOn: true, isOwnWindow: false))
        XCTAssertFalse(WorkspaceScanner.isStripThumbnail(serverBounds: small, isOnScreen: true, axFrame: nil,
                                                         stageManagerOn: true, isOwnWindow: false))
        XCTAssertFalse(WorkspaceScanner.isStripThumbnail(serverBounds: CGRect(x: 0, y: 0, width: 500, height: 300),
                                                         isOnScreen: true, axFrame: axFrame,
                                                         stageManagerOn: true, isOwnWindow: false))
    }

    // MARK: (d) our own windows are never thumbnails

    func testOwnWindowIsNeverAThumbnail() {
        XCTAssertTrue(WorkspaceScanner.isOwnWindow(pid: 42, appName: "Other", bundleID: nil, ownPID: 42))
        XCTAssertTrue(WorkspaceScanner.isOwnWindow(pid: 1, appName: "Windows Manager", bundleID: nil, ownPID: 42))
        XCTAssertTrue(WorkspaceScanner.isOwnWindow(pid: 1, appName: "X", bundleID: WorkspaceScanner.ownBundleID, ownPID: 42))
        XCTAssertFalse(WorkspaceScanner.isOwnWindow(pid: 1, appName: "TextEdit", bundleID: "com.apple.TextEdit", ownPID: 42))

        XCTAssertFalse(WorkspaceScanner.isStripThumbnail(serverBounds: CGRect(x: 0, y: 0, width: 118, height: 97),
                                                         isOnScreen: true, axFrame: axFrame,
                                                         stageManagerOn: true, isOwnWindow: true))
        let ownApp = AppRef(bundleID: WorkspaceScanner.ownBundleID, name: "Windows Manager", path: nil)
        let own = window(7, bounds: CGRect(x: 0, y: 0, width: 118, height: 97), onScreen: true, pid: 1,
                         app: "Windows Manager")
        let scan = assemble([own], ax: [7: details(axFrame)], stageManagerOn: true, app: ownApp)
        XCTAssertTrue(scan.windows.isEmpty)
    }
}
