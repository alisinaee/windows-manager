import CoreGraphics
import XCTest
@testable import WMCore

final class WindowDumpTests: XCTestCase {
    private let uuid = "1A2B3C4D-0000-1111-2222-333344445555"

    private func fakeScan(stageManagerOn: Bool?, windows: [LiveWindow]) -> WorkspaceScan {
        let display = DisplayIdentity(uuid: uuid, name: "Built-in", vendorID: 0, modelID: 0, serial: 0,
                                      frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                      visibleFrame: CGRect(x: 0, y: 25, width: 1512, height: 957),
                                      isMain: true, isBuiltIn: true)
        return WorkspaceScan(displays: [display], windows: windows, stageManagerOn: stageManagerOn)
    }

    func testHeaderAndEmptyScan() {
        XCTAssertEqual(WindowDump.lines(for: fakeScan(stageManagerOn: nil, windows: [])),
                       ["stageManagerOn=nil windows=0"])
        XCTAssertEqual(WindowDump.lines(for: fakeScan(stageManagerOn: true, windows: [])),
                       ["stageManagerOn=true windows=0"])
    }

    func testOneLinePerWindowAfterHeader() {
        let scan = fakeScan(stageManagerOn: false, windows: [
            LiveWindow(windowID: 1, app: AppRef(bundleID: nil, name: "Safari"), frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
            LiveWindow(windowID: 2, app: AppRef(bundleID: nil, name: "Notes"), frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
        ])
        let lines = WindowDump.lines(for: scan)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].hasPrefix("win id=1 app=Safari "))
        XCTAssertTrue(lines[2].hasPrefix("win id=2 app=Notes "))
    }

    func testFullWindowLineWithStageInfo() {
        var window = LiveWindow(windowID: 77, app: AppRef(bundleID: "com.apple.Terminal", name: "Terminal"),
                                frame: CGRect(x: 100.4, y: 200, width: 1200, height: 800), displayUUID: uuid,
                                isOnCurrentSpace: true, isOnScreen: true,
                                stage: SavedStage(group: 2, isActive: false, isHeuristic: true))
        window.serverBounds = CGRect(x: 90, y: 180, width: 1220, height: 820)
        window.isStripThumbnail = true
        let line = WindowDump.lines(for: fakeScan(stageManagerOn: true, windows: [window]))[1]
        XCTAssertEqual(line, "win id=77 app=Terminal layer=- onscreen=true bounds=1220x820@90,180 "
            + "ax=1200x800@100,200 display=1A2B3C4D currentSpace=true stage=strip group=2 heuristic=true thumb=true")
    }

    func testUnknownFieldsPrintDashesAndNil() {
        let window = LiveWindow(windowID: 5, app: AppRef(bundleID: nil, name: "Mail"),
                                frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let line = WindowDump.lines(for: fakeScan(stageManagerOn: nil, windows: [window]))[1]
        XCTAssertEqual(line, "win id=5 app=Mail layer=- onscreen=nil bounds=- ax=300x200@0,0 display=- "
            + "currentSpace=true stage=unknown group=- heuristic=- thumb=false")
    }

    func testActiveStageReported() {
        var window = LiveWindow(windowID: 9, app: AppRef(bundleID: nil, name: "Xcode"),
                                frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                stage: SavedStage(group: 0, isActive: true, isHeuristic: false))
        window.isOnScreen = false
        let line = WindowDump.lines(for: fakeScan(stageManagerOn: true, windows: [window]))[1]
        XCTAssertTrue(line.contains(" stage=active group=0 heuristic=false "))
        XCTAssertTrue(line.contains(" onscreen=false "))
    }
}
