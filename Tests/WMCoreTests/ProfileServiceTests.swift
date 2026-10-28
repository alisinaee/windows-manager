import CoreGraphics
import XCTest
@testable import WMCore

final class ProfileServiceTests: XCTestCase {
    private var folder: URL!
    private var svc: ProfileService!
    private var launch: LaunchOrderService!
    private let main = DisplayIdentity(uuid: "D1", name: "Main", frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                       visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800), isMain: true, isBuiltIn: true)
    private let safari = AppRef(bundleID: "com.apple.Safari", name: "Safari")
    private let notes = AppRef(bundleID: "com.apple.Notes", name: "Notes")

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID().uuidString)")
        let store = ProfileStore(folder: folder)
        svc = ProfileService(store: store)
        launch = LaunchOrderService(store: store)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func blank(_ name: String = "Work") throws -> Profile { try svc.createBlank(name: name, displays: [main]) }

    func testCreateListShowCopyRenameDelete() throws {
        let p = try blank()
        XCTAssertEqual(svc.list().count, 1)
        XCTAssertEqual(try svc.show("work").id, p.id)
        XCTAssertEqual(try svc.show(p.id.uuidString).name, "Work")
        XCTAssertThrowsError(try svc.createBlank(name: "WORK")) { XCTAssertEqual($0 as? ServiceError, .conflict("A profile named \"WORK\" already exists.")) }
        XCTAssertThrowsError(try svc.createBlank(name: "  ")) { guard case .invalid = $0 as? ServiceError else { return XCTFail() } }
        let c = try svc.copy("Work")
        XCTAssertEqual(c.name, "Work copy")
        XCTAssertNotEqual(c.id, p.id)
        XCTAssertEqual(try svc.rename("Work copy", to: "Home").name, "Home")
        XCTAssertThrowsError(try svc.rename("Home", to: "Work")) { guard case .conflict = $0 as? ServiceError else { return XCTFail() } }
        try svc.delete("Home")
        XCTAssertEqual(svc.list().count, 1)
        XCTAssertThrowsError(try svc.show("Home")) { guard case .notFound = $0 as? ServiceError else { return XCTFail() } }
    }

    func testIconAndShortcut() throws {
        _ = try blank("A"); _ = try blank("B")
        XCTAssertEqual(try svc.setIcon("A", icon: "briefcase").icon, "briefcase")
        XCTAssertEqual(try svc.setIcon("A", icon: nil).icon, Profile.defaultIcon)
        XCTAssertThrowsError(try svc.setIcon("A", icon: "has space"))
        XCTAssertEqual(try svc.setShortcut("A", shortcut: "ctrl+opt+cmd+1").options.hotkey, "ctrl+opt+cmd+1")
        XCTAssertThrowsError(try svc.setShortcut("B", shortcut: "cmd+opt+ctrl+1")) { guard case .conflict = $0 as? ServiceError else { return XCTFail() } }
        XCTAssertThrowsError(try svc.setShortcut("B", shortcut: "cmd+1x")) { guard case .invalid = $0 as? ServiceError else { return XCTFail() } }
        XCTAssertNil(try svc.clearShortcut("A").options.hotkey)
        XCTAssertEqual(try svc.setShortcut("B", shortcut: "ctrl+opt+cmd+1").options.hotkey, "ctrl+opt+cmd+1")
    }

    func testOptionsKeepHotkey() throws {
        _ = try blank()
        _ = try svc.setShortcut("Work", shortcut: "ctrl+opt+2")
        let p = try svc.setOptions("Work") { $0.restoreSpaces = false; $0.otherApps = .hide; $0.hotkey = nil }
        XCTAssertFalse(p.options.restoreSpaces)
        XCTAssertEqual(p.options.otherApps, .hide)
        XCTAssertEqual(p.options.hotkey, "ctrl+opt+2")
    }

    func testWindowsFramesAndSnaps() throws {
        _ = try blank()
        let (_, w1) = try svc.addWindow("Work", app: safari, display: "D1")
        let (_, w2) = try svc.addWindow("Work", app: notes, display: "D1")
        var p = try svc.setWindowFrame("Work", window: w1, frame: CGRect(x: 10, y: 10, width: 500, height: 400))
        XCTAssertEqual(p.windows.first { $0.id == w1 }?.frame, CGRect(x: 10, y: 10, width: 500, height: 400))
        XCTAssertEqual(p.windows.first { $0.id == w1 }?.relativeFrame.width ?? 0, 500.0 / 1200, accuracy: 0.001)
        p = try svc.applyZone("Work", window: w2, zone: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1), zoneName: "Right")
        let z = p.windows.first { $0.id == w2 }!
        XCTAssertEqual(z.frame, CGRect(x: 600, y: 0, width: 600, height: 800))
        XCTAssertEqual(z.zoneName, "Right")
        p = try svc.applyGridSnap("Work", window: w1, grid: GridSpec(columns: 12, rows: 8))
        XCTAssertEqual(p.windows.first { $0.id == w1 }?.frame.minX, 0)
        XCTAssertThrowsError(try svc.setWindowFrame("Work", window: UUID(), frame: CGRect(x: 0, y: 0, width: 5, height: 5))) {
            guard case .notFound = $0 as? ServiceError else { return XCTFail() }
        }
        XCTAssertThrowsError(try svc.setWindowFrame("Work", window: w1, frame: .zero)) { guard case .invalid = $0 as? ServiceError else { return XCTFail() } }
        p = try svc.applyMagnetSnap("Work", window: w1)
        XCTAssertEqual(p.windows.count, 2)
    }

    func testAutoLayout() throws {
        _ = try blank()
        _ = try svc.addWindow("Work", app: safari, display: "D1")
        _ = try svc.addWindow("Work", app: notes, display: "D1")
        XCTAssertGreaterThanOrEqual(try svc.autoLayoutCandidates("Work", display: "D1", desktop: 1).count, 2)
        let p = try svc.applyAutoLayout("Work", display: "D1", desktop: 1)
        XCTAssertEqual(Set(p.windows.map(\.frame.width)).count, 2)   // main 2/3 + side 1/3
        XCTAssertThrowsError(try svc.applyAutoLayout("Work", display: "D1", desktop: 1, candidate: 9))
    }

    func testRemoveAndDesktops() throws {
        _ = try blank()
        let r = try svc.addDesktop("Work", display: "D1")
        XCTAssertEqual(r.number, 2)
        let (_, w) = try svc.addWindow("Work", app: safari, display: "D1", desktop: 2)
        XCTAssertThrowsError(try svc.addWindow("Work", app: safari, display: "D1", desktop: 7))
        XCTAssertEqual(try svc.moveWindow("Work", window: w, display: "D1", desktop: 1).windows[0].placement, .desktop(number: 1))
        XCTAssertTrue(try svc.removeApp("Work", app: "com.apple.safari").windows.isEmpty)
        XCTAssertThrowsError(try svc.removeApp("Work", app: "nothing")) { guard case .notFound = $0 as? ServiceError else { return XCTFail() } }
    }

    func testExportImport() throws {
        _ = try blank()
        _ = try svc.addWindow("Work", app: safari, display: "D1")
        let file = folder.deletingLastPathComponent().appendingPathComponent("export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try svc.export("Work", to: file)
        let imported = try svc.importFile(file)
        XCTAssertEqual(imported.name, "Work 2")
        XCTAssertEqual(imported.windows.count, 1)
        XCTAssertThrowsError(try svc.importData(Data("nope".utf8))) { guard case .invalid = $0 as? ServiceError else { return XCTFail() } }
    }

    func testLaunchOrder() throws {
        _ = try blank()
        _ = try svc.addWindow("Work", app: safari, display: "D1")
        _ = try svc.addWindow("Work", app: notes, display: "D1")
        var v = try launch.get("Work")
        XCTAssertTrue(v.isImplicit)
        XCTAssertEqual(v.requests.count, 2)
        var p = try launch.setMode("Work", mode: .sequential)
        XCTAssertEqual(p.launchPlan?.mode, .sequential)
        p = try launch.move("Work", item: "notes", toPosition: 1)
        XCTAssertEqual(p.launchPlan?.items.first?.app.name, "Notes")
        p = try launch.setDelay("Work", item: "2", seconds: 500)
        XCTAssertEqual(p.launchPlan?.items[1].delayAfter, 60)
        p = try launch.setTimeout("Work", item: "Safari", seconds: 30)
        XCTAssertEqual(p.launchPlan?.items[1].timeout, 30)
        p = try launch.setEnabled("Work", item: "Safari", enabled: false)
        v = try launch.get("Work")
        XCTAssertEqual(v.requests.map(\.app.name), ["Notes"])
        p = try launch.addApp("Work", app: AppRef(bundleID: "com.apple.Music", name: "Music"))
        XCTAssertEqual(p.launchPlan?.items.last?.withoutWindows, true)
        XCTAssertThrowsError(try launch.addApp("Work", app: notes)) { guard case .conflict = $0 as? ServiceError else { return XCTFail() } }
        XCTAssertThrowsError(try launch.setDelay("Work", item: "zzz", seconds: 1)) { guard case .notFound = $0 as? ServiceError else { return XCTFail() } }
        p = try launch.setOrder("Work", items: ["music"])
        XCTAssertEqual(p.launchPlan?.items.first?.app.name, "Music")
        p = try launch.reset("Work")
        XCTAssertNil(p.launchPlan)
    }
}
