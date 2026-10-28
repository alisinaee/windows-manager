import CoreGraphics
import Foundation
import XCTest
@testable import WMCore

final class SettingsLayoutRuleServiceTests: XCTestCase {
    private var dir: URL!
    private var suite: String!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID().uuidString)")
        suite = "wm.test.\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    // MARK: Settings

    func testSettingsDefaultsSetResetAndValidation() throws {
        let s = try SettingsStore(suiteName: suite)
        XCTAssertEqual(try s.get("debugMode"), .bool(false))
        try s.set("debugMode", text: "on")
        XCTAssertEqual(try s.get("debugMode"), .bool(true))
        XCTAssertEqual(UserDefaults(suiteName: suite)?.bool(forKey: "debugMode"), true)
        try s.set("studioSidebarWidth", .int(300))
        XCTAssertEqual(try s.get("studioSidebarWidth"), .double(300))
        XCTAssertThrowsError(try s.set("studioSidebarWidth", .double(5))) { XCTAssertEqual(($0 as? ServiceError)?.code, "invalid") }
        XCTAssertThrowsError(try s.set("debugMode", text: "maybe"))
        XCTAssertThrowsError(try s.get("nope")) { XCTAssertEqual(($0 as? ServiceError)?.code, "not_found") }
        XCTAssertFalse(try XCTUnwrap(s.list().first { $0.key == "debugMode" }).isDefault)
        try s.reset("debugMode")
        XCTAssertEqual(try s.get("debugMode"), .bool(false))
    }

    func testSettingsJSONFieldsKeepOtherFields() throws {
        let s = try SettingsStore(suiteName: suite)
        try s.set("snap.gap", .double(12))
        try s.set("snap.modifier", text: "shift")
        XCTAssertThrowsError(try s.set("snap.modifier", text: "hyper"))
        XCTAssertEqual(try s.get("snap.gap"), .double(12))
        let data = try XCTUnwrap(UserDefaults(suiteName: suite)?.data(forKey: "snapSettings"))
        let decoded = try JSONDecoder().decode(SnapSettings.self, from: data)
        XCTAssertEqual(decoded.gap, 12)
        XCTAssertEqual(decoded.modifier, .shift)
        try s.resetAll()
        XCTAssertEqual(try s.get("snap.gap"), .double(0))
        XCTAssertNil(UserDefaults(suiteName: suite)?.data(forKey: "snapSettings"))
    }

    func testGrids() throws {
        let s = try SettingsStore(suiteName: suite)
        XCTAssertEqual(s.grid(display: "abc"), MonitorGridSetting())
        try s.setGrid(display: "abc", isOn: true, columns: 8)
        XCTAssertEqual(s.grid(display: "ABC"), MonitorGridSetting(isOn: true, spec: GridSpec(columns: 8, rows: 6)))
        XCTAssertThrowsError(try s.setGrid(display: "abc", rows: 100))
        try s.resetGrid(display: "abc")
        XCTAssertTrue(s.grids().isEmpty)
    }

    // MARK: Layouts

    func testLayoutCRUD() throws {
        let svc = LayoutService(store: LayoutStore(folder: dir))
        let a = try svc.create(name: "Dev", displayKey: "abc")
        XCTAssertEqual(a.displayKey, "ABC")
        XCTAssertThrowsError(try svc.create(name: "dev")) { XCTAssertEqual(($0 as? ServiceError)?.code, "conflict") }
        XCTAssertThrowsError(try svc.create(name: "  ")) { XCTAssertEqual(($0 as? ServiceError)?.code, "invalid") }
        var l = try svc.addZone(to: "Dev", name: "Left", rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(l.zones.count, 1)
        XCTAssertThrowsError(try svc.addZone(to: "Dev", name: "Bad", rect: NormalizedRect(x: 0.8, y: 0, width: 0.5, height: 1)))
        l = try svc.assign(bundleID: "com.apple.Safari", to: "left", in: a.id.uuidString)
        XCTAssertEqual(l.apps(in: l.zones[0].id), ["com.apple.Safari"])
        XCTAssertThrowsError(try svc.assign(bundleID: "nope", to: "Left", in: "Dev"))
        l = try svc.rename("Dev", to: "Work")
        XCTAssertEqual(try svc.zones(of: "work").count, 1)
        l = try svc.removeZone(from: "Work", zone: "Left")
        XCTAssertTrue(l.zones.isEmpty)
        try svc.delete("Work")
        XCTAssertTrue(try svc.list().isEmpty)
        XCTAssertThrowsError(try svc.get("Work")) { XCTAssertEqual(($0 as? ServiceError)?.code, "not_found") }
    }

    func testSaveFromFrames() throws {
        let svc = LayoutService(store: LayoutStore(folder: dir))
        let display = CGRect(x: 100, y: 50, width: 1000, height: 500)
        let l = try svc.saveFromFrames(name: "Halves", displayFrame: display,
                                       frames: [CGRect(x: 100, y: 50, width: 500, height: 500), CGRect(x: 600, y: 50, width: 500, height: 500)],
                                       zoneNames: ["A"])
        XCTAssertEqual(l.zones.map(\.name), ["A", "Zone 2"])
        XCTAssertEqual(l.zones[1].rect, NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertThrowsError(try svc.saveFromFrames(name: "halves", displayFrame: display, frames: [display])) {
            XCTAssertEqual(($0 as? ServiceError)?.code, "conflict")
        }
        let again = try svc.saveFromFrames(name: "halves", displayFrame: display, frames: [display], overwrite: true)
        XCTAssertEqual(again.id, l.id)
        XCTAssertEqual(try svc.list().count, 1)
    }

    // MARK: Rules

    private func rules() -> RuleService {
        RuleService(autoProfile: AutoProfileStore(fileURL: dir.appendingPathComponent("auto.json")),
                    pins: PinRulesStore(directory: dir), windowRules: WindowRulesStore(file: dir.appendingPathComponent("wr.json")))
    }

    func testAutoProfile() throws {
        let r = rules()
        XCTAssertFalse(r.autoProfile().enabled)
        let id = UUID()
        var s = try r.updateAutoProfile(enabled: true, wake: false, delaySeconds: 5)
        XCTAssertTrue(s.enabled); XCTAssertFalse(s.triggers.wake); XCTAssertEqual(s.delaySeconds, 5)
        XCTAssertThrowsError(try r.updateAutoProfile(cooldownSeconds: -1))
        s = try r.setAutoProfileMapping(monitorSetKey: "K", profileID: id)
        XCTAssertEqual(r.autoProfile().mapping["K"], id)
        s = try r.removeAutoProfileMapping(monitorSetKey: "K")
        XCTAssertTrue(s.mapping.isEmpty)
        XCTAssertThrowsError(try r.removeAutoProfileMapping(monitorSetKey: "K")) { XCTAssertEqual(($0 as? ServiceError)?.code, "not_found") }
    }

    func testPins() throws {
        let r = rules()
        let p = try r.addPin(bundleID: "com.apple.Safari", titleContains: " ", target: .desktopIndex(number: 2, displayUUID: "D"))
        XCTAssertNil(p.titleContains)
        XCTAssertThrowsError(try r.addPin(bundleID: "com.apple.safari", target: .desktopIndex(number: 2, displayUUID: "D"))) {
            XCTAssertEqual(($0 as? ServiceError)?.code, "conflict")
        }
        XCTAssertThrowsError(try r.addPin(bundleID: "x", target: .spaceID(1)))
        XCTAssertThrowsError(try r.addPin(bundleID: "a.b", target: .desktopIndex(number: 0, displayUUID: "D")))
        let u = try r.updatePin(p.id, titleContains: .some("Mail"), target: .spaceID(7))
        XCTAssertEqual(u.titleContains, "Mail")
        XCTAssertEqual(r.pins().count, 1)
        try r.removePin(p.id)
        XCTAssertThrowsError(try r.removePin(p.id)) { XCTAssertEqual(($0 as? ServiceError)?.code, "not_found") }
    }

    func testWindowRules() throws {
        let r = rules()
        try r.setWindowRule(bundleID: "com.apple.Notes", action: .ignore)
        try r.setWindowRule(bundleID: "com.apple.notes", action: .alwaysRestore)
        XCTAssertEqual(r.windowRules().count, 1)
        XCTAssertEqual(try r.windowRule(bundleID: "com.apple.Notes").action, .alwaysRestore)
        XCTAssertThrowsError(try r.setWindowRule(bundleID: "bad", action: .ignore))
        try r.removeWindowRule(bundleID: "COM.apple.notes")
        XCTAssertThrowsError(try r.windowRule(bundleID: "com.apple.Notes")) { XCTAssertEqual(($0 as? ServiceError)?.code, "not_found") }
    }
}
