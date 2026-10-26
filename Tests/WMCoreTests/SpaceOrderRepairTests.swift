import Foundation
import Testing
@testable import WMCore

/// Tests for the Space order repair. The planner is pure; the executor runs only against fakes, so no preference
/// is written, no backup is taken and the Dock is never restarted.
@Suite struct SpaceOrderRepairTests {
    typealias F = SpaceOrderFileTests

    // MARK: Fixture

    /// Live Main display, same order as the stored fixture: FS Chrome, FS Telegram, Desktop 1, FS Arc, FS Claude.
    static func mainLive() -> DisplaySpaces {
        let parts: [(String, SpaceKind, String?)] = [
            (F.chrome, .fullscreen, "Google Chrome"), (F.telegram, .fullscreen, "Telegram"), ("", .desktop, nil),
            (F.arc, .fullscreen, "Arc"), (F.claude, .fullscreen, "Claude"),
        ]
        return live("Main", parts)
    }

    /// External display: FS Code, FS Code, Desktop.
    static func extLive() -> DisplaySpaces {
        live(F.extUUID, [(F.code1, .fullscreen, "Code"), (F.code2, .fullscreen, "Code"), (F.extDesktop, .desktop, nil)])
    }

    static func live(_ id: String, _ parts: [(String, SpaceKind, String?)]) -> DisplaySpaces {
        let spaces = parts.enumerated().map { index, part in
            SpaceInfo(id: UInt64(index + 1), uuid: part.0, kind: part.1, index: index, isCurrent: index == 0,
                      ownerAppNames: part.2.map { [$0] } ?? [])
        }
        return DisplaySpaces(displayIdentifier: id, displayName: nil, currentSpaceID: 1, spaces: spaces)
    }

    static func order(_ id: String, _ keys: [String]) -> DisplaySpaceOrder {
        DisplaySpaceOrder(displayID: id, name: nil, slots: keys.map { SpaceSlot(key: $0, label: $0) })
    }

    static let mainWanted = order("Main", ["fullscreen:Google Chrome", "fullscreen:Telegram", "desktop:1",
                                           "fullscreen:Claude", "fullscreen:Arc"])

    static func makePlan(expected: [DisplaySpaceOrder], live: [DisplaySpaces],
                         config: [String: Any] = F.config()) -> RepairPlan {
        let actual = live.map(DisplaySpaceOrder.init(displaySpaces:))
        let report = SpaceGuard.evaluate(expected: expected, actual: actual, mruSpaces: false)
        return SpaceOrderRepair.plan(report: report, expected: expected, storedConfig: config, liveDisplays: live)
    }

    static func mainPlan() -> RepairPlan { makePlan(expected: [mainWanted], live: [mainLive()]) }

    // MARK: Planner

    @Test func planKeepsCorrectPrefixAndMovesFromFirstWrongSlot() throws {
        let plan = Self.mainPlan()
        #expect(plan.isRunnable)
        let item = try #require(plan.reorders.first)
        #expect(item.firstWrongSlot == 3)
        #expect(Array(item.desiredUUIDs.prefix(3)) == Array(F.mainOrder.prefix(3)))
        #expect(item.desiredUUIDs == [F.chrome, F.telegram, "", F.claude, F.arc])
        #expect(Set(item.desiredUUIDs) == Set(item.currentUUIDs))
        #expect(item.movedCount == 2)
        #expect(plan.summary.contains("Move 2 Desktops") == false)
        #expect(plan.summary.contains("Move 2 Spaces on Display 1"))
        #expect(plan.summary.contains("A backup is saved first."))
    }

    @Test func extraSpaceGoesToTheEndAndIsNeverDeleted() throws {
        let wanted = Self.order("Main", ["fullscreen:Google Chrome", "desktop:1", "fullscreen:Telegram"])
        let plan = Self.makePlan(expected: [wanted], live: [Self.mainLive()])
        let item = try #require(plan.reorders.first)
        #expect(item.desiredUUIDs.count == 5)
        #expect(item.desiredUUIDs == [F.chrome, "", F.telegram, F.arc, F.claude])
        #expect(Set(item.desiredUUIDs) == Set(F.mainOrder))
    }

    @Test func cleanDisplayProducesEmptyPlan() {
        let same = Self.order("Main", ["fullscreen:Google Chrome", "fullscreen:Telegram", "desktop:1",
                                       "fullscreen:Arc", "fullscreen:Claude"])
        let plan = Self.makePlan(expected: [same], live: [Self.mainLive()])
        #expect(plan.isEmpty)
        #expect(!plan.isRunnable)
    }

    @Test func ambiguousSameAppFullScreenDisplayIsSkippedAndBlocks() {
        let wanted = Self.order(F.extUUID, ["desktop:1", "fullscreen:Code", "fullscreen:Code#2"])
        let plan = Self.makePlan(expected: [Self.mainWanted, wanted], live: [Self.mainLive(), Self.extLive()])
        #expect(plan.reorders.count == 1)
        #expect(!plan.blockingReasons.isEmpty)
        #expect(!plan.isRunnable)
        let skipped = plan.items.contains {
            if case .skipped(let id, _, .ambiguous) = $0 { return id == F.extUUID }
            return false
        }
        #expect(skipped)
    }

    @Test func storedOrderThatDiffersFromLiveBlocks() {
        var live = Self.mainLive()
        live.spaces.swapAt(0, 1)
        for i in live.spaces.indices { live.spaces[i].index = i }
        let plan = Self.makePlan(expected: [Self.mainWanted], live: [live])
        #expect(!plan.isRunnable)
        #expect(plan.blockingReasons.first?.contains("stored order differs") == true)
    }

    @Test func missingDisplayIsSkippedWithoutBlocking() {
        let gone = Self.order("GONE", ["desktop:1"])
        let plan = Self.makePlan(expected: [Self.mainWanted, gone], live: [Self.mainLive()])
        #expect(plan.isRunnable)
        #expect(plan.items.contains { if case .skipped(_, _, .notConnected) = $0 { return true } else { return false } })
    }

    // MARK: Executor fakes

    final class World: @unchecked Sendable {
        var log: [String] = []
        var config: [String: Any] = F.config()
        var written: [String: Any]?
        var backupFails = false
        var killStatus: Int32 = 0
        /// Live order returned after the Dock restart; nil = keep returning the old order.
        var liveAfterRestart: [String: [String]]?
        var restarted = false
        var sleeps = 0

        func deps() -> RepairDependencies {
            RepairDependencies(
                readConfig: { self.log.append("read"); return self.config },
                writeConfig: { self.log.append("write"); self.written = $0 },
                backup: { reason in
                    self.log.append("backup:\(reason)")
                    if self.backupFails { throw SpaceBindingsBackupError.backupFailed("disk full") }
                    return BackupInfo(url: URL(fileURLWithPath: "/fake/2026-01-01-before-order-repair.plist"),
                                      date: Date(timeIntervalSince1970: 0), reason: reason)
                },
                runner: Runner(self),
                readLiveOrder: {
                    self.log.append("live")
                    if self.restarted, let after = self.liveAfterRestart { return after }
                    return ["Main": F.mainOrder]
                },
                sleep: { _ in self.sleeps += 1 }
            )
        }
    }

    final class Runner: CommandRunning, @unchecked Sendable {
        let world: World
        init(_ world: World) { self.world = world }
        func run(_ path: String, arguments: [String]) throws -> CommandResult {
            world.log.append("run:\(path) \(arguments.joined(separator: " "))")
            world.restarted = true
            return CommandResult(status: world.killStatus)
        }
    }

    static let wantedLive = ["Main": [F.chrome, F.telegram, "", F.claude, F.arc]]

    // MARK: Executor

    @Test func refusesWithoutConfirmation() async {
        let world = World()
        await #expect(throws: SpaceOrderRepairError.notConfirmed) {
            try await SpaceOrderRepair.run(Self.mainPlan(), confirmed: false, deps: world.deps())
        }
        #expect(world.log.isEmpty)
    }

    @Test func refusesEmptyAndBlockedPlans() async {
        let world = World()
        await #expect(throws: SpaceOrderRepairError.nothingToRepair) {
            try await SpaceOrderRepair.run(RepairPlan(items: []), confirmed: true, deps: world.deps())
        }
        let blocked = RepairPlan(items: Self.mainPlan().items + [.skipped(displayID: "X", name: nil, reason: .ambiguous("x"))])
        await #expect(throws: (any Error).self) {
            try await SpaceOrderRepair.run(blocked, confirmed: true, deps: world.deps())
        }
        #expect(world.log.isEmpty)
    }

    @Test func backupFailureAbortsBeforeAnyWrite() async {
        let world = World()
        world.backupFails = true
        await #expect(throws: (any Error).self) {
            try await SpaceOrderRepair.run(Self.mainPlan(), confirmed: true, deps: world.deps())
        }
        #expect(world.log == ["backup:before order repair"])
        #expect(world.written == nil)
    }

    @Test func writesAfterBackupAndRestartsDockExactlyOnce() async throws {
        let world = World()
        world.liveAfterRestart = Self.wantedLive
        let result = try await SpaceOrderRepair.run(Self.mainPlan(), confirmed: true, deps: world.deps())
        #expect(result.isRepaired)
        #expect(world.log.first == "backup:before order repair")
        #expect(world.log.filter { $0 == "write" }.count == 1)
        #expect(world.log.filter { $0.hasPrefix("run:") } == ["run:/usr/bin/killall Dock"])
        let backupAt = try #require(world.log.firstIndex { $0.hasPrefix("backup") })
        let writeAt = try #require(world.log.firstIndex(of: "write"))
        let runAt = try #require(world.log.firstIndex { $0.hasPrefix("run:") })
        #expect(backupAt < writeAt && writeAt < runAt)
        let written = try #require(world.written)
        #expect(F.display("Main", in: written)?.monitorUUIDs == Self.wantedLive["Main"])
    }

    @Test func verifyFailureNeedsAttentionWithBackupNameAndKeepsTheWrite() async throws {
        let world = World()   // live order never changes
        let result = try await SpaceOrderRepair.run(Self.mainPlan(), confirmed: true, deps: world.deps())
        guard case .needsAttention(let name, let instruction) = result.outcome else {
            Issue.record("expected needsAttention")
            return
        }
        #expect(name == "2026-01-01-before-order-repair.plist")
        #expect(instruction.contains(name))
        #expect(world.sleeps == 16)
        #expect(world.log.filter { $0.hasPrefix("run:") }.count == 1)
        #expect(world.log.filter { $0 == "write" }.count == 1)   // no automatic restore
    }

    @Test func staleStoredOrderIsRefusedBeforeWriting() async {
        let world = World()
        world.config = F.config()
        var changed = Self.mainPlan()
        if case .reorder(var item) = changed.items[0] {
            item.currentUUIDs = item.currentUUIDs.reversed()
            changed.items[0] = .reorder(item)
        }
        await #expect(throws: (any Error).self) {
            try await SpaceOrderRepair.run(changed, confirmed: true, deps: world.deps())
        }
        #expect(world.written == nil)
        #expect(!world.log.contains { $0.hasPrefix("run:") })
    }
}
