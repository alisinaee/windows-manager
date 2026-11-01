import XCTest
@testable import WMCore

final class UXScreenChoiceTests: XCTestCase {
    private let screens = [
        UXScreenChoice.Screen(name: "Built-in Retina Display", area: 100),
        UXScreenChoice.Screen(name: "ASUS PA248QV", area: 300),
        UXScreenChoice.Screen(name: "DELL U2720Q", area: 200),
    ]

    func testNameMatchesCaseInsensitivelyExactOrContains() {
        XCTAssertEqual(UXScreenChoice.pick("PA248QV", screens: screens), 1)
        XCTAssertEqual(UXScreenChoice.pick("pa248", screens: screens), 1)
        XCTAssertEqual(UXScreenChoice.pick("dell u2720q", screens: screens), 2)
        XCTAssertNil(UXScreenChoice.pick("nonesuch", screens: screens))
    }

    func testExactNameBeatsContains() {
        let s = [UXScreenChoice.Screen(name: "LG HDR 4K Pro", area: 1), UXScreenChoice.Screen(name: "LG HDR 4K", area: 1)]
        XCTAssertEqual(UXScreenChoice.pick("LG HDR 4K", screens: s), 1)
    }

    func testIndexSecondaryLargest() {
        XCTAssertEqual(UXScreenChoice.pick("2", screens: screens), 1)
        XCTAssertNil(UXScreenChoice.pick("4", screens: screens))
        XCTAssertNil(UXScreenChoice.pick("0", screens: screens))
        XCTAssertEqual(UXScreenChoice.pick("secondary", screens: screens), 1)
        XCTAssertNil(UXScreenChoice.pick("secondary", screens: [screens[0]]))
        XCTAssertEqual(UXScreenChoice.pick("largest", screens: screens), 1)
        XCTAssertNil(UXScreenChoice.pick("", screens: screens))
    }
}
