import XCTest
@testable import WMCore

final class UXOpenRouteTests: XCTestCase {
    func testFullRoute() throws {
        let url = URL(string: "windowsmanager://open?section=studio&profile=Work%20Setup&mode=edit&sheet=save&inspectorTab=launch&appearance=dark&size=900x600")!
        let r = try UXOpenRoute.parse(url: url)
        XCTAssertEqual(r, UXOpenRoute(section: .studio, profile: "Work Setup", mode: .edit, sheet: .save,
                                      inspectorTab: .launch, appearance: .dark, size: CGSize(width: 900, height: 600)))
    }

    func testNewKeys() throws {
        let r = try UXOpenRoute.parse(url: URL(string: "windowsmanager://open?section=onboarding&permission=after&selectTile=2&saveName=Work%20Setup")!)
        XCTAssertEqual(r, UXOpenRoute(section: .onboarding, permission: .after, selectTile: 2, saveName: "Work Setup"))
        XCTAssertThrowsError(try UXOpenRoute.parse(url: URL(string: "windowsmanager://open?section=studio&selectTile=-1")!))
        XCTAssertThrowsError(try UXOpenRoute.parse(url: URL(string: "windowsmanager://open?section=onboarding&permission=x")!))
    }

    func testShortcutSheetAndSidebar() throws {
        let r = try UXOpenRoute.parse(url: URL(string: "windowsmanager://open?section=studio&profile=Work&sheet=shortcut&sidebar=collapsed")!)
        XCTAssertEqual(r, UXOpenRoute(section: .studio, profile: "Work", sheet: .shortcut, sidebar: .collapsed))
        XCTAssertThrowsError(try UXOpenRoute.parse(url: URL(string: "windowsmanager://open?section=studio&sidebar=half")!))
    }

    func testSectionOnly() throws {
        let r = try UXOpenRoute.parse(url: URL(string: "windowsmanager://open?section=popover")!)
        XCTAssertEqual(r, UXOpenRoute(section: .popover))
    }

    func testErrors() {
        func parse(_ s: String) -> Error? { do { _ = try UXOpenRoute.parse(url: URL(string: s)!); return nil } catch { return error } }
        XCTAssertEqual(parse("windowsmanager://run?profile=x") as? UXOpenRoute.ParseError, .notOpenRoute)
        XCTAssertEqual(parse("windowsmanager://open") as? UXOpenRoute.ParseError, .invalid(key: "section", value: ""))
        XCTAssertEqual(parse("windowsmanager://open?section=nope") as? UXOpenRoute.ParseError, .invalid(key: "section", value: "nope"))
        XCTAssertEqual(parse("windowsmanager://open?section=studio&mode=x") as? UXOpenRoute.ParseError, .invalid(key: "mode", value: "x"))
        XCTAssertEqual(parse("windowsmanager://open?section=studio&size=10x10") as? UXOpenRoute.ParseError, .invalid(key: "size", value: "10x10"))
    }

    func testEnabledOnlyWithEnv() {
        XCTAssertTrue(UXOpenRoute.isEnabled(environment: ["WM_UX_TEST": "1"]))
        XCTAssertFalse(UXOpenRoute.isEnabled(environment: ["WM_UX_TEST": "0"]))
        XCTAssertFalse(UXOpenRoute.isEnabled(environment: [:]))
    }

    func testControlCommandStillRejectsOpen() {
        XCTAssertThrowsError(try ControlCommand.parse(url: URL(string: "windowsmanager://open?section=studio")!))
    }
}
