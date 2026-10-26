import XCTest
@testable import WMCore

final class LiveWindowInfoTests: XCTestCase {
    func testMinimizedByIDMapsMatchingIDs() {
        let map = LiveWindowInfo.minimizedByID([(windowID: 1, isMinimized: false), (windowID: 2, isMinimized: true)])
        XCTAssertEqual(map, [1: false, 2: true])
    }

    func testMinimizedByIDSkipsEntriesWithoutID() {
        let map = LiveWindowInfo.minimizedByID([(windowID: nil, isMinimized: true), (windowID: 5, isMinimized: true)])
        XCTAssertEqual(map, [5: true])
    }

    func testMinimizedByIDKeepsFirstDuplicate() {
        let map = LiveWindowInfo.minimizedByID([(windowID: 9, isMinimized: true), (windowID: 9, isMinimized: false)])
        XCTAssertEqual(map, [9: true])
    }

    func testMinimizedByIDEmptyInput() {
        XCTAssertEqual(LiveWindowInfo.minimizedByID([]), [:])
    }

    func testIsMinimizedLooksUpMatchedWindow() {
        XCTAssertTrue(LiveWindowInfo.isMinimized(windowID: 3, in: [3: true]))
        XCTAssertFalse(LiveWindowInfo.isMinimized(windowID: 3, in: [3: false]))
    }

    func testIsMinimizedDefaultsToFalseWhenUnmatched() {
        XCTAssertFalse(LiveWindowInfo.isMinimized(windowID: 42, in: [:]))
        XCTAssertFalse(LiveWindowInfo.isMinimized(windowID: 42, in: [1: true]))
    }
}
