import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite struct SizeLimitProbeCacheTests {
    private func tempStore() -> SizeLimitStore {
        SizeLimitStore(file: FileManager.default.temporaryDirectory
            .appendingPathComponent("size-limits-\(UUID().uuidString).json"))
    }

    @Test func probedFreeEntryIsRecordedAndNotProbedAgain() {
        let store = tempStore()
        #expect(store.needsProbe(bundleID: "com.example.app", title: "Settings 1"))
        store.record(WindowResizeLimits(probed: true), bundleID: "com.example.app", title: "Settings 1")
        #expect(!store.needsProbe(bundleID: "com.example.app", title: "Settings 2"))
        #expect(store.needsProbe(bundleID: "com.example.app", title: "Other"))
        let back = store.limits(bundleID: "com.example.app", title: "Settings")
        #expect(back?.probed == true)
        #expect(back?.hasRestrictions == false)
    }

    @Test func effectiveLimitsMergesCache() {
        let store = tempStore()
        store.record(WindowResizeLimits(maxSize: CGSize(width: 700, height: CGFloat.greatestFiniteMagnitude), probed: true),
                     bundleID: "com.example.app", title: nil)
        let own = WindowResizeLimits(minSize: CGSize(width: 300, height: 200))
        let merged = SizeLimitLearning.effectiveLimits(own: own, bundleID: "com.example.app", title: nil, store: store)
        #expect(merged?.minSize?.width == 300)
        #expect(merged?.maxSize?.width == 700)
        #expect(SizeLimitLearning.effectiveLimits(own: nil, bundleID: "com.other", title: nil, store: store) == nil)
    }

    @Test func cachedFixedWidthBlocksWidth() {
        let store = tempStore()
        store.record(WindowResizeLimits(fixedWidth: true, probed: true), bundleID: "com.example.app", title: nil)
        let limits = SizeLimitLearning.effectiveLimits(own: WindowResizeLimits(), bundleID: "com.example.app",
                                                       title: nil, store: store)
        #expect(limits?.fixedWidth == true)
        let current = CGRect(x: 0, y: 0, width: 400, height: 300)
        let out = limits!.clamp(CGRect(x: 0, y: 0, width: 600, height: 350), current: current)
        #expect(out.width == 400)
        #expect(out.height == 350)
    }

    @Test func oldJSONWithoutProbedMarkerDecodes() throws {
        let json = #"{"app|":{"fixedWidth":true,"fixedHeight":false,"canMove":true}}"#
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("size-limits-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: file)
        let store = SizeLimitStore(file: file)
        let l = store.limits(bundleID: "app", title: nil)
        #expect(l?.fixedWidth == true)
        #expect(l?.probed == false)
        #expect(!store.needsProbe(bundleID: "app", title: nil))
    }
}
