import Foundation
import XCTest
@testable import WMCore

final class ZoneSelectionTests: XCTestCase {
    func testPlainTapReplacesSelection() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(ZoneSelection.afterTap([a, b], tapped: c, extend: false), [c])
        XCTAssertEqual(ZoneSelection.afterTap([], tapped: a, extend: false), [a])
    }

    func testExtendAddsMissingZone() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(ZoneSelection.afterTap([a], tapped: b, extend: true), [a, b])
    }

    func testExtendRemovesZoneAlreadySelected() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(ZoneSelection.afterTap([a, b], tapped: a, extend: true), [b])
        XCTAssertEqual(ZoneSelection.afterTap([a], tapped: a, extend: true), [])
    }

    func testExtendOnEmptySelectionSelectsTappedZone() {
        let a = UUID()
        XCTAssertEqual(ZoneSelection.afterTap([], tapped: a, extend: true), [a])
    }

    func testPrimaryIsTheOnlySelectedZone() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(ZoneSelection.primary(in: [a], tapped: nil), a)
        XCTAssertEqual(ZoneSelection.primary(in: [a], tapped: b), a)
    }

    func testPrimaryIsTappedZoneWhenStillSelected() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(ZoneSelection.primary(in: [a, b], tapped: b), b)
    }

    func testPrimaryIsNilForEmptyOrAmbiguousSelection() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertNil(ZoneSelection.primary(in: [], tapped: nil))
        XCTAssertNil(ZoneSelection.primary(in: [a, b], tapped: c))
        XCTAssertNil(ZoneSelection.primary(in: [a, b], tapped: nil))
    }
}
