import CoreGraphics
import Foundation
import XCTest
@testable import WMCore

final class SizeLimitLearningTests: XCTestCase {
    func testClassifyMatched() {
        let r = CGRect(x: 10, y: 20, width: 500, height: 400)
        XCTAssertEqual(SizeLimitLearning.classify(requested: r, actual: r), .matched)
    }

    func testClassifyClampedWhenPositionRight() {
        let r = CGRect(x: 1387, y: 143, width: 684, height: 1015)
        let a = CGRect(x: 1387, y: 143, width: 385, height: 616)
        XCTAssertEqual(SizeLimitLearning.classify(requested: r, actual: a), .sizeClamped(actual: CGSize(width: 385, height: 616)))
    }

    func testClassifyPositionOffAndUnreadable() {
        let r = CGRect(x: 100, y: 100, width: 500, height: 400)
        XCTAssertEqual(SizeLimitLearning.classify(requested: r, actual: CGRect(x: 300, y: 100, width: 400, height: 400)), .positionOff)
        XCTAssertEqual(SizeLimitLearning.classify(requested: r, actual: nil), .positionOff)
    }

    func testNote() {
        XCTAssertEqual(SizeLimitLearning.note(for: CGSize(width: 740, height: 893)), "app limits size to 740x893")
    }

    func testLearnFixedWhenResultEqualsPrevious() {
        let l = SizeLimitLearning.learn(requested: CGSize(width: 684, height: 1015), observed: CGSize(width: 385, height: 616),
                                        previous: CGSize(width: 385, height: 616))
        XCTAssertEqual(l?.fixedWidth, true)
        XCTAssertEqual(l?.fixedHeight, true)
    }

    func testLearnFixedWidthMaxHeight() {
        let l = SizeLimitLearning.learn(requested: CGSize(width: 1217, height: 1119), observed: CGSize(width: 740, height: 893),
                                        previous: CGSize(width: 740, height: 600))
        XCTAssertEqual(l?.fixedWidth, true)
        XCTAssertEqual(l?.fixedHeight, false)
        XCTAssertEqual(l?.maxSize?.height, 893)
    }

    func testLearnMinWhenAppWontShrink() {
        let l = SizeLimitLearning.learn(requested: CGSize(width: 100, height: 300), observed: CGSize(width: 320, height: 300),
                                        previous: CGSize(width: 800, height: 300))
        XCTAssertEqual(l?.minSize?.width, 320)
        XCTAssertEqual(l?.fixedWidth, false)
        XCTAssertFalse(l?.fixedHeight ?? true)
    }

    func testLearnNothingWhenMatched() {
        XCTAssertNil(SizeLimitLearning.learn(requested: CGSize(width: 5, height: 5), observed: CGSize(width: 5, height: 5), previous: nil))
    }

    func testMergeKeepsAndTightens() {
        let a = WindowResizeLimits(fixedWidth: true, maxSize: CGSize(width: 900, height: 900))
        let b = WindowResizeLimits(fixedHeight: true, maxSize: CGSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        let m = SizeLimitLearning.merge(a, with: b)
        XCTAssertEqual(m?.fixedWidth, true)
        XCTAssertEqual(m?.fixedHeight, true)
        XCTAssertEqual(m?.maxSize, CGSize(width: 700, height: 900))
        XCTAssertEqual(SizeLimitLearning.merge(nil, with: b), b)
        XCTAssertEqual(SizeLimitLearning.merge(a, with: nil), a)
        XCTAssertFalse(SizeLimitLearning.adds(SizeLimitLearning.merge(a, with: a), to: a))
    }

    func testTitleKind() {
        XCTAssertEqual(SizeLimitLearning.titleKind("Doc 12  Draft"), "doc draft")
        XCTAssertEqual(SizeLimitLearning.titleKind(nil), "")
    }

    func testStoreRoundTripAndFallback() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)/size-limits.json")
        let store = SizeLimitStore(file: file)
        XCTAssertNil(store.limits(bundleID: "com.x", title: nil))
        store.record(WindowResizeLimits(fixedWidth: true), bundleID: "com.x", title: nil)
        store.record(WindowResizeLimits(fixedHeight: true), bundleID: "com.x", title: nil)
        let got = SizeLimitStore(file: file).limits(bundleID: "COM.X", title: "Anything 3")
        XCTAssertEqual(got?.fixedWidth, true)
        XCTAssertEqual(got?.fixedHeight, true)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}
