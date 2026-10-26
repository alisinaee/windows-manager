import Foundation
import Testing
@testable import WMCore

/// Tests for the pure parts of AXRemoteWindows: the token bytes and the per-pid cache rules.
/// The only system calls are cheap process checks; no AX element is created.
@Suite struct AXRemoteWindowsTests {
    // MARK: Token bytes

    @Test func tokenHasTwentyBytes() {
        #expect(AXRemoteWindows.tokenLength == 20)
        #expect(AXRemoteWindows.token(pid: 1, elementID: 0).count == 20)
        #expect(AXRemoteWindows.token(pid: .max, elementID: .max).count == 20)
    }

    @Test func tokenLayoutForSmallValues() {
        let token = AXRemoteWindows.token(pid: 1, elementID: 0)
        #expect(Array(token) == [
            0x01, 0x00, 0x00, 0x00,  // pid, little-endian
            0x00, 0x00, 0x00, 0x00,  // zero
            0x6f, 0x63, 0x6f, 0x63,  // 0x636f636f, little-endian
            0, 0, 0, 0, 0, 0, 0, 0,  // element id
        ])
    }

    @Test func tokenLayoutForMultiByteValues() {
        let token = AXRemoteWindows.token(pid: 0x0102_0304, elementID: 0x1122_3344_5566_7788)
        #expect(Array(token) == [
            0x04, 0x03, 0x02, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x6f, 0x63, 0x6f, 0x63,
            0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
        ])
    }

    @Test func tokenElementIDOccupiesTheLastEightBytes() {
        let token = Array(AXRemoteWindows.token(pid: 4242, elementID: 1000))
        #expect(Array(token[0..<4]) == [0x92, 0x10, 0x00, 0x00])  // 4242 = 0x1092
        #expect(Array(token[12..<20]) == [0xe8, 0x03, 0, 0, 0, 0, 0, 0])  // 1000 = 0x03e8
    }

    @Test func tokenMarkerIsNotTheAsciiOrder() {
        // The bytes "coco" in text order do not work; the UInt32 0x636f636f written little-endian does.
        #expect(AXRemoteWindows.tokenMarker == 0x636f636f)
        let token = Array(AXRemoteWindows.token(pid: 1, elementID: 7))
        #expect(Array(token[8..<12]) != Array("coco".utf8))
        #expect(Array(token[8..<12]) == Array("ococ".utf8))
    }

    @Test func tokenTreatsAPidAsRawBits() {
        let token = Array(AXRemoteWindows.token(pid: -1, elementID: 0))
        #expect(Array(token[0..<4]) == [0xff, 0xff, 0xff, 0xff])
    }

    @Test func tokensDifferOnlyInTheirElementID() {
        let a = Array(AXRemoteWindows.token(pid: 99, elementID: 5))
        let b = Array(AXRemoteWindows.token(pid: 99, elementID: 6))
        #expect(Array(a[0..<12]) == Array(b[0..<12]))
        #expect(a[12] == 5 && b[12] == 6)
    }

    // MARK: Cache

    private typealias TestCache = AXRemoteWindows.Cache<String>

    @Test func emptyCacheKnowsNothing() {
        let cache = TestCache()
        #expect(cache.windows(pid: 100).isEmpty)
        #expect(cache.pids.isEmpty)
    }

    @Test func storeKeepsWindowsPerPid() {
        var cache = TestCache()
        cache.store([10: "a", 11: "b"], pid: 100)
        cache.store([20: "c"], pid: 200)
        #expect(cache.windows(pid: 100) == [10: "a", 11: "b"])
        #expect(cache.windows(pid: 200) == [20: "c"])
        #expect(cache.pids == [100, 200])
    }

    @Test func storeMergesAndReplacesByWindowID() {
        var cache = TestCache()
        cache.store([10: "a", 11: "b"], pid: 100)
        cache.store([11: "b2", 12: "c"], pid: 100)
        #expect(cache.windows(pid: 100) == [10: "a", 11: "b2", 12: "c"])
    }

    @Test func storingNothingCreatesNoEntry() {
        var cache = TestCache()
        cache.store([:], pid: 100)
        #expect(cache.pids.isEmpty)
    }

    @Test func invalidateForgetsOnlyThatPid() {
        var cache = TestCache()
        cache.store([10: "a"], pid: 100)
        cache.store([20: "b"], pid: 200)
        cache.invalidate(pid: 100)
        #expect(cache.windows(pid: 100).isEmpty)
        #expect(cache.windows(pid: 200) == [20: "b"])
        #expect(cache.pids == [200])
    }

    @Test func invalidatingAnUnknownPidChangesNothing() {
        var cache = TestCache()
        cache.store([10: "a"], pid: 100)
        cache.invalidate(pid: 999)
        #expect(cache.windows(pid: 100) == [10: "a"])
    }

    @Test func invalidateAllEmptiesTheCache() {
        var cache = TestCache()
        cache.store([10: "a"], pid: 100)
        cache.store([20: "b"], pid: 200)
        cache.invalidateAll()
        #expect(cache.pids.isEmpty)
        #expect(cache.windows(pid: 100).isEmpty)
    }

    @Test func removeDropsSingleWindows() {
        var cache = TestCache()
        cache.store([10: "a", 11: "b", 12: "c"], pid: 100)
        cache.remove(windowIDs: [10, 12, 99], pid: 100)
        #expect(cache.windows(pid: 100) == [11: "b"])
    }

    @Test func removingTheLastWindowDropsThePid() {
        var cache = TestCache()
        cache.store([10: "a"], pid: 100)
        cache.remove(windowIDs: [10], pid: 100)
        #expect(cache.pids.isEmpty)
    }

    @Test func removeOnAnUnknownPidChangesNothing() {
        var cache = TestCache()
        cache.store([10: "a"], pid: 100)
        cache.remove(windowIDs: [10], pid: 5)
        #expect(cache.windows(pid: 100) == [10: "a"])
    }

    @Test func cacheCanBeRefilledAfterInvalidation() {
        var cache = TestCache()
        cache.store([10: "old"], pid: 100)
        cache.invalidate(pid: 100)
        cache.store([10: "new"], pid: 100)
        #expect(cache.windows(pid: 100) == [10: "new"])
    }

    // MARK: Public entry points that need no live app

    @Test func nothingWantedMeansNothingDone() {
        let result = AXRemoteWindows.resolve(pid: getpid(), wanted: [])
        #expect(result.elements.isEmpty)
        #expect(result.scanStop == .notNeeded)
        #expect(AXRemoteWindows.bruteForce(pid: getpid(), wanted: []).probed == 0)
    }

    @Test func aProcessThatDoesNotExistGivesNothing() {
        // Far above any real pid limit; kill(pid, 0) reports ESRCH.
        let pid: pid_t = 0x7fff_fff0
        AXRemoteWindows.invalidate(pid: pid)
        let result = AXRemoteWindows.resolve(pid: pid, wanted: [1, 2])
        #expect(result.elements.isEmpty)
        #expect(result.scanStop == .appNotRunning)
        #expect(AXRemoteWindows.windows(pid: pid).isEmpty)
        #expect(AXRemoteWindows.element(forWindowID: 1, pid: pid) == nil)
        #expect(AXRemoteWindows.bruteForce(pid: pid).stop == .appNotRunning)
    }

    @Test func invalidatingUnknownPidsIsHarmless() {
        AXRemoteWindows.invalidate(pid: 0x7fff_ffe0)
        AXRemoteWindows.invalidateAll()
    }
}

@Suite struct AXRemoteDirectWindowsTests {
    @Test func firstByWindowIDKeepsFirstElementPerID() {
        let result = AXRemoteWindows.firstByWindowID([(5500, "main"), (5500, "focused"), (5502, "panel")])
        #expect(result == [5500: "main", 5502: "panel"])
    }

    @Test func firstByWindowIDEmpty() {
        #expect(AXRemoteWindows.firstByWindowID([(UInt32, String)]()).isEmpty)
    }
}
