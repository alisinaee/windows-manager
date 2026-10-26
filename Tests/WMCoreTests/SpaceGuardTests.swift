import Foundation
import Testing
@testable import WMCore

/// Pure tests for the Space guard. They never read the real Spaces or Dock settings.
@Suite struct SpaceGuardTests {
    private static func display(_ id: String, _ keys: [String]) -> DisplaySpaceOrder {
        DisplaySpaceOrder(displayID: id, name: id == "Main" ? "Built-in" : id,
                          slots: keys.map { SpaceSlot(key: $0, label: $0) })
    }

    private static let expected = [
        display("Main", ["desktop:1", "desktop:2", "fullscreen:Safari", "desktop:3"]),
        display("EXT", ["desktop:1", "desktop:2"]),
    ]

    @Test func cleanOrderHasNoDriftAndNoFixPlan() {
        let report = SpaceGuard.evaluate(expected: Self.expected, actual: Self.expected, mruSpaces: false)
        #expect(report.isClean)
        #expect(report.drifts.isEmpty)
        #expect(report.fixPlan == nil)
        #expect(report.mruSpacesWarning == nil)
    }

    @Test func emptyExpectedOrderIsAlwaysClean() {
        let report = SpaceGuard.evaluate(expected: [], actual: Self.expected, mruSpaces: false)
        #expect(report.isClean)
    }

    @Test func swappedPairReportsFirstWrongSlotAndMovedSpaces() throws {
        let actual = [
            Self.display("Main", ["desktop:2", "desktop:1", "fullscreen:Safari", "desktop:3"]),
            Self.expected[1],
        ]
        let report = SpaceGuard.evaluate(expected: Self.expected, actual: actual, mruSpaces: false)
        #expect(!report.isClean)
        #expect(report.drifts.count == 1)
        let drift = try #require(report.drifts.first)
        #expect(drift.displayID == "Main")
        #expect(drift.firstWrongSlot == 0)
        #expect(drift.expected?.key == "desktop:1")
        #expect(drift.actual?.key == "desktop:2")
        #expect(drift.movedKeys == ["desktop:1", "desktop:2"])
        #expect(drift.extraKeys.isEmpty && drift.missingKeys.isEmpty)
        let plan = try #require(report.fixPlan)
        #expect(plan.displayID == "Main")
        #expect(plan.fromSlot == 0)
        #expect(plan.description.contains("slot 1"))
    }

    @Test func laterDifferenceStartsFixAtThatSlot() throws {
        let actual = [
            Self.display("Main", ["desktop:1", "desktop:2", "desktop:3", "fullscreen:Safari"]),
            Self.expected[1],
        ]
        let report = SpaceGuard.evaluate(expected: Self.expected, actual: actual, mruSpaces: false)
        let drift = try #require(report.drifts.first)
        #expect(drift.firstWrongSlot == 2)
        #expect(report.fixPlan?.fromSlot == 2)
    }

    @Test func extraSpaceIsReported() throws {
        let actual = [
            Self.display("Main", ["desktop:1", "desktop:2", "fullscreen:Safari", "desktop:3", "desktop:4"]),
            Self.expected[1],
        ]
        let report = SpaceGuard.evaluate(expected: Self.expected, actual: actual, mruSpaces: false)
        let drift = try #require(report.drifts.first)
        #expect(drift.extraKeys == ["desktop:4"])
        #expect(drift.missingKeys.isEmpty)
        #expect(drift.movedKeys.isEmpty)
        #expect(drift.firstWrongSlot == 4)
        #expect(drift.expected == nil)
        #expect(!report.isClean)
    }

    @Test func missingDisplayIsReportedButHasNoFixPlan() {
        let actual = [Self.expected[0]]
        let report = SpaceGuard.evaluate(expected: Self.expected, actual: actual, mruSpaces: false)
        #expect(report.missingDisplayIDs == ["EXT"])
        #expect(report.drifts.isEmpty)
        #expect(!report.isClean)
        #expect(report.fixPlan == nil)
    }

    @Test func missingSpaceOnDisplayIsReported() throws {
        let actual = [
            Self.display("Main", ["desktop:1", "desktop:2", "desktop:3"]),
            Self.expected[1],
        ]
        let report = SpaceGuard.evaluate(expected: Self.expected, actual: actual, mruSpaces: false)
        let drift = try #require(report.drifts.first)
        #expect(drift.missingKeys == ["fullscreen:Safari"])
        #expect(drift.extraKeys.isEmpty)
    }

    @Test func mruOnAddsWarningWithoutAffectingClean() {
        let report = SpaceGuard.evaluate(expected: Self.expected, actual: Self.expected, mruSpaces: true)
        #expect(report.isClean)
        let warning = report.mruSpacesWarning ?? ""
        #expect(warning.contains("Automatically rearrange Spaces based on most recent use"))
        #expect(warning.contains("System Settings > Desktop & Dock"))
    }

    @Test func mruNotSetWarnsBecauseDefaultIsOn() {
        let report = SpaceGuard.evaluate(expected: Self.expected, actual: Self.expected, mruSpaces: nil)
        #expect(report.mruSpacesWarning?.contains("default") == true)
    }

    @Test func mruOffHasNoWarning() {
        let report = SpaceGuard.evaluate(expected: Self.expected, actual: Self.expected, mruSpaces: false)
        #expect(report.mruSpacesWarning == nil)
    }

    @Test func settingsDecodeOldJSONWithDefaults() throws {
        let settings = try JSONDecoder().decode(SpaceGuardSettings.self, from: Data("{}".utf8))
        #expect(settings == SpaceGuardSettings())
        #expect(!settings.hasExpectedOrder)
    }

    @Test func settingsRoundTripExpectedOrder() throws {
        var settings = SpaceGuardSettings(watchEnabled: true, autoFix: true)
        settings.setExpected(Self.expected, source: "Current order")
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(SpaceGuardSettings.self, from: data)
        #expect(back == settings)
        #expect(back.hasExpectedOrder)
        #expect(back.expectedSource == "Current order")
    }

    @Test func duplicateFullScreenKeysGetSuffix() {
        let slots = SpaceGuard.uniqueSlots([("fullscreen:Safari", "a"), ("fullscreen:Safari", "b"), ("desktop:1", "c")])
        #expect(slots.map(\.key) == ["fullscreen:Safari", "fullscreen:Safari#2", "desktop:1"])
    }

    // MARK: Watcher

    private final class Feed {
        var orders: [[DisplaySpaceOrder]]
        var mru: Bool? = false
        var index = 0
        init(_ orders: [[DisplaySpaceOrder]]) { self.orders = orders }
        func next() -> [DisplaySpaceOrder] {
            let order = orders[min(index, orders.count - 1)]
            index += 1
            return order
        }
    }

    private static let drifted = [
        display("Main", ["desktop:2", "desktop:1", "fullscreen:Safari", "desktop:3"]),
        expected[1],
    ]

    @Test func watcherDebouncesTransientDrift() {
        let feed = Feed([Self.drifted, Self.expected, Self.drifted, Self.expected])
        var fired = 0
        let watcher = DriftWatcher(expected: Self.expected, confirmations: 2, reader: { feed.next() },
                                   mruSpaces: { feed.mru }, onDrift: { _ in fired += 1 })
        for _ in 0..<4 { watcher.poll() }
        #expect(fired == 0)
    }

    @Test func watcherFiresOncePerNewDrift() {
        let feed = Feed([Self.drifted])
        var reports: [SpaceGuardReport] = []
        let watcher = DriftWatcher(expected: Self.expected, confirmations: 2, reader: { feed.next() },
                                   mruSpaces: { false }, onDrift: { reports.append($0) })
        watcher.poll()
        #expect(reports.isEmpty)
        watcher.poll()
        #expect(reports.count == 1)
        watcher.poll()
        watcher.poll()
        #expect(reports.count == 1)
        #expect(watcher.lastReport?.isClean == false)
    }

    @Test func watcherFiresAgainAfterCleanAndNewDrift() {
        let feed = Feed([Self.drifted, Self.drifted, Self.expected, Self.drifted, Self.drifted])
        var count = 0
        let watcher = DriftWatcher(expected: Self.expected, confirmations: 2, reader: { feed.next() },
                                   mruSpaces: { false }, onDrift: { _ in count += 1 })
        for _ in 0..<5 { watcher.poll() }
        #expect(count == 2)
    }

    @Test func watcherReaderErrorDoesNotFire() {
        struct Boom: Error {}
        var count = 0
        let watcher = DriftWatcher(expected: Self.expected, confirmations: 1, reader: { throw Boom() },
                                   mruSpaces: { false }, onDrift: { _ in count += 1 })
        #expect(watcher.poll() == nil)
        #expect(watcher.lastError != nil)
        #expect(count == 0)
    }
}
