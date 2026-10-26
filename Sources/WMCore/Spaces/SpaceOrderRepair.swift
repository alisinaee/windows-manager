import Foundation

// P3.3 Space order repair: put the Spaces of a drifted display back in the expected order, starting at the
// first wrong slot, by rewriting com.apple.spaces and restarting the Dock once.
//
// `SpaceOrderRepair.plan` is pure: it reads a config dictionary and the live Spaces, and changes nothing.
// `SpaceOrderRepair.run` does the risky part, and only through `RepairDependencies`, so tests use fakes.
// The repair never creates or deletes a Space: the new order is always a permutation of the current Spaces.
// A backup is taken before anything is written, and a failed check is never undone automatically.

// MARK: - Plan

public struct RepairPlan: Equatable, Sendable {
    /// One display that will be reordered.
    public struct Reorder: Equatable, Sendable {
        /// Identifier of the stored Monitors entry ("Main" or a display UUID).
        public var displayID: String
        public var name: String?
        /// 1-based number of the display among the live displays, for people ("Display 1").
        public var displayNumber: Int
        /// 0-based first slot that is wrong; every slot before it stays where it is.
        public var firstWrongSlot: Int
        /// Space uuids now, in Mission Control order.
        public var currentUUIDs: [String]
        /// Space uuids wanted, same Spaces, new order.
        public var desiredUUIDs: [String]
        /// Slot keys of the Spaces that change position.
        public var movedKeys: [String]

        public var movedCount: Int { movedKeys.count }
        public var title: String { name ?? "Display \(displayNumber)" }
    }

    public enum SkipReason: Equatable, Sendable {
        /// The display is already in the expected order.
        case clean
        /// Only extra or missing Spaces differ; moving the Spaces that exist would change nothing.
        case nothingToMove
        /// The display is not connected now.
        case notConnected
        /// Spaces cannot be matched uniquely (same-app full-screen Spaces, duplicate display, ...). Blocks the repair.
        case ambiguous(String)
        /// The stored preferences are not in a shape this repair writes safely. Blocks the repair.
        case unsafeStoredLayout(String)

        /// A blocking reason makes the whole repair refuse, so nothing is half fixed.
        public var isBlocking: Bool {
            switch self {
            case .ambiguous, .unsafeStoredLayout: return true
            case .clean, .nothingToMove, .notConnected: return false
            }
        }

        public var text: String {
            switch self {
            case .clean: return "already in the expected order"
            case .nothingToMove: return "only extra or missing Spaces differ, nothing can be moved"
            case .notConnected: return "not connected"
            case .ambiguous(let detail), .unsafeStoredLayout(let detail): return detail
            }
        }
    }

    public enum Item: Equatable, Sendable {
        case reorder(Reorder)
        case skipped(displayID: String, name: String?, reason: SkipReason)
    }

    public var items: [Item]

    public init(items: [Item]) { self.items = items }

    public var reorders: [Reorder] {
        items.compactMap { if case .reorder(let r) = $0 { return r } else { return nil } }
    }

    /// Reasons that stop the repair.
    public var blockingReasons: [String] {
        items.compactMap {
            if case .skipped(let id, let name, let reason) = $0, reason.isBlocking { return "\(name ?? id): \(reason.text)" }
            return nil
        }
    }

    /// Nothing to reorder.
    public var isEmpty: Bool { reorders.isEmpty }

    /// Ready to run: something to move and nothing blocking.
    public var isRunnable: Bool { !isEmpty && blockingReasons.isEmpty }

    /// Plain-English text for the confirmation alert.
    public var summary: String {
        if !blockingReasons.isEmpty {
            return "The order cannot be repaired safely: " + blockingReasons.joined(separator: " ")
        }
        guard !isEmpty else { return "Nothing to repair." }
        let moves = reorders.map { r -> String in
            let noun = r.movedKeys.allSatisfy { $0.hasPrefix("desktop:") }
                ? (r.movedCount == 1 ? "Desktop" : "Desktops") : (r.movedCount == 1 ? "Space" : "Spaces")
            return "Move \(r.movedCount) \(noun) on \(r.title) to their saved positions."
        }
        return (moves + ["Mission Control and the Dock will flicker for a few seconds. Open windows are not closed. A backup is saved first."])
            .joined(separator: " ")
    }
}

// MARK: - Execution types

public enum SpaceOrderRepairError: Error, Equatable, LocalizedError {
    case notConfirmed
    case nothingToRepair
    case blocked(String)
    /// The backup failed, so nothing was written.
    case backupFailed(String)
    /// The stored order moved since the plan was made, or the new config was refused. Nothing was written.
    case refused(String)
    /// Writing failed. A backup exists (named in the text).
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfirmed: return "The repair needs confirmation. Nothing was changed."
        case .nothingToRepair: return "There is nothing to repair. Nothing was changed."
        case .blocked(let text): return "The order cannot be repaired safely: \(text) Nothing was changed."
        case .backupFailed(let text): return "The backup failed, so the order was not changed: \(text)"
        case .refused(let text): return "The repair was refused and nothing was written: \(text)"
        case .writeFailed(let text): return "Writing the Space order failed: \(text)"
        }
    }
}

public struct RepairResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case repaired
        /// The live order did not match after the Dock restart. Nothing was undone.
        case needsAttention(backupName: String, instruction: String)
    }

    public var outcome: Outcome
    public var backup: BackupInfo
    public var message: String

    public var isRepaired: Bool { outcome == .repaired }
}

/// Everything the executor touches. `live` is the real thing; tests pass fakes.
public struct RepairDependencies: @unchecked Sendable {
    public var readConfig: () throws -> [String: Any]
    public var writeConfig: ([String: Any]) throws -> Void
    /// Takes the backup; the argument is the reason.
    public var backup: (String) throws -> BackupInfo
    public var runner: CommandRunning
    /// Live Space uuids per display identifier, in Mission Control order. Throws while the Dock is restarting.
    public var readLiveOrder: () throws -> [String: [String]]
    public var sleep: (TimeInterval) async -> Void
    /// How long to wait for the live order after the Dock restart, and how often to look.
    public var verifyTimeout: TimeInterval
    public var pollInterval: TimeInterval

    public init(readConfig: @escaping () throws -> [String: Any],
                writeConfig: @escaping ([String: Any]) throws -> Void,
                backup: @escaping (String) throws -> BackupInfo,
                runner: CommandRunning,
                readLiveOrder: @escaping () throws -> [String: [String]],
                sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                verifyTimeout: TimeInterval = 8,
                pollInterval: TimeInterval = 0.5) {
        self.readConfig = readConfig
        self.writeConfig = writeConfig
        self.backup = backup
        self.runner = runner
        self.readLiveOrder = readLiveOrder
        self.sleep = sleep
        self.verifyTimeout = verifyTimeout
        self.pollInterval = pollInterval
    }

    /// Real preferences, real backup folder, real Dock. Only the app calls this, after the user confirms.
    public static func live(backup: SpaceBindingsBackup = SpaceBindingsBackup()) -> RepairDependencies {
        RepairDependencies(
            readConfig: { try SpaceOrderFile.readDomain() },
            writeConfig: { try SpaceOrderFile.write($0) },
            backup: { try backup.backupNow(reason: $0) },
            runner: ProcessCommandRunner(),
            readLiveOrder: {
                var result: [String: [String]] = [:]
                for display in try SpaceReader.displays() { result[display.displayIdentifier] = display.spaces.map(\.uuid) }
                return result
            }
        )
    }
}

// MARK: - Planner and executor

public enum SpaceOrderRepair {
    /// Builds the repair plan. Pure: reads only its arguments.
    ///
    /// Per drifted display the Spaces before the first wrong slot stay. From there the Spaces that exist are put in
    /// the expected order; Spaces that were not expected go to the end. A display is skipped when it is clean, not
    /// connected, or its Spaces cannot be matched uniquely; the last two kinds of skip that can make a write unsafe
    /// are blocking.
    public static func plan(report: SpaceGuardReport, expected: [DisplaySpaceOrder], storedConfig: [String: Any],
                            liveDisplays: [DisplaySpaces]) -> RepairPlan {
        let inspection = SpaceOrderFile.inspect(storedConfig)
        var items: [RepairPlan.Item] = []

        for drift in report.drifts {
            let id = drift.displayID
            func skip(_ reason: RepairPlan.SkipReason) {
                items.append(.skipped(displayID: id, name: drift.name, reason: reason))
            }
            let lives = liveDisplays.enumerated().filter { same($0.element.displayIdentifier, id) }
            guard let (liveIndex, live) = lives.first else { skip(.notConnected); continue }
            guard lives.count == 1 else { skip(.ambiguous("\(lives.count) displays share the identifier \(id).")); continue }
            guard let wanted = expected.first(where: { same($0.displayID, id) }) else {
                skip(.ambiguous("no expected order is saved for this display.")); continue
            }

            let liveKeys = DisplaySpaceOrder(displaySpaces: live).slots.map(\.key)
            let uuids = live.spaces.map(\.uuid)
            let wantKeys = wanted.slots.map(\.key)
            guard let first = (0..<max(liveKeys.count, wantKeys.count)).first(where: {
                $0 >= liveKeys.count || $0 >= wantKeys.count || liveKeys[$0] != wantKeys[$0]
            }) else { skip(.clean); continue }

            let restKeys = Array(liveKeys.dropFirst(first))
            let wantRest = Array(wantKeys.dropFirst(first))
            if (restKeys + wantRest).contains(where: { $0.contains("#") || $0 == "other" }) {
                skip(.ambiguous("Spaces from slot \(first + 1) on cannot be told apart (same-app full-screen or system Spaces).")); continue
            }
            guard Set(uuids).count == uuids.count, Set(liveKeys).count == liveKeys.count else {
                skip(.ambiguous("the live Spaces have repeated identifiers.")); continue
            }

            var uuidForKey: [String: String] = [:]
            for (key, uuid) in zip(liveKeys, uuids) { uuidForKey[key] = uuid }
            let restUUIDs = Array(uuids.dropFirst(first))
            var desiredRest = wantRest.compactMap { uuidForKey[$0] }
            let placed = Set(desiredRest)
            desiredRest += restUUIDs.filter { !placed.contains($0) }   // extras keep their relative order, at the end
            let desired = Array(uuids.prefix(first)) + desiredRest
            guard desired.count == uuids.count, Set(desired) == Set(uuids) else {
                skip(.ambiguous("the new order is not a permutation of the current Spaces.")); continue
            }
            guard desired != uuids else { skip(.nothingToMove); continue }
            if uuids.first == "" && desired.first != "" {
                skip(.unsafeStoredLayout("this would move the first Desktop of the main display away from position 1.")); continue
            }

            // The stored preferences must be the layout this repair understands and must agree with the live order.
            guard inspection.layout.isUsable else {
                skip(.unsafeStoredLayout("the stored layout is not understood (\(inspection.layout.problems.joined(separator: "; "))).")); continue
            }
            let stored = inspection.displays.filter { same($0.displayIdentifier, id) }
            guard stored.count == 1, let entry = stored.first, entry.problems.isEmpty, entry.orderingIndex != nil else {
                skip(.unsafeStoredLayout("the stored entry for this display is missing, repeated or incomplete.")); continue
            }
            guard entry.monitorUUIDs == uuids else {
                skip(.unsafeStoredLayout("the stored order differs from the live order; check again first.")); continue
            }

            let movedKeys = zip(zip(uuids, desired), liveKeys).filter { $0.0.0 != $0.0.1 }.map(\.1)
            items.append(.reorder(.init(displayID: entry.displayIdentifier, name: drift.name ?? live.displayName,
                                        displayNumber: liveIndex + 1, firstWrongSlot: first,
                                        currentUUIDs: uuids, desiredUUIDs: desired, movedKeys: movedKeys)))
        }

        for id in report.missingDisplayIDs {
            items.append(.skipped(displayID: id, name: nil, reason: .notConnected))
        }
        return RepairPlan(items: items)
    }

    /// Runs the repair. Order of steps: confirmation, plan checks, BACKUP, write, one Dock restart, wait for and
    /// verify the live order. A failed verification returns `.needsAttention`; nothing is restored automatically.
    public static func run(_ plan: RepairPlan, confirmed: Bool, deps: RepairDependencies) async throws -> RepairResult {
        guard confirmed else { throw SpaceOrderRepairError.notConfirmed }
        guard !plan.isEmpty else { throw SpaceOrderRepairError.nothingToRepair }
        if !plan.blockingReasons.isEmpty { throw SpaceOrderRepairError.blocked(plan.blockingReasons.joined(separator: " ")) }

        let backup: BackupInfo
        do {
            backup = try deps.backup("before order repair")
        } catch {
            throw SpaceOrderRepairError.backupFailed(error.localizedDescription)
        }
        let name = backup.url.lastPathComponent

        var config: [String: Any]
        do {
            config = try deps.readConfig()
            let stored = SpaceOrderFile.inspect(config).displays
            for item in plan.reorders {
                guard stored.first(where: { same($0.displayIdentifier, item.displayID) })?.monitorUUIDs == item.currentUUIDs else {
                    throw SpaceOrderRepairError.refused("the stored order of \(item.title) changed since the plan was made.")
                }
                config = try SpaceOrderFile.reordered(config, displayID: item.displayID, newOrderUUIDs: item.desiredUUIDs)
            }
        } catch let error as SpaceOrderRepairError {
            throw error
        } catch {
            throw SpaceOrderRepairError.refused(error.localizedDescription)
        }
        do {
            try deps.writeConfig(config)
        } catch {
            throw SpaceOrderRepairError.writeFailed("\(error.localizedDescription) The backup \(name) was saved first.")
        }

        func attention(_ detail: String) -> RepairResult {
            RepairResult(outcome: .needsAttention(
                backupName: name,
                instruction: "\(detail) Nothing was undone. Check Mission Control. To go back, open Windows Manager Settings > Spaces > Backups, "
                    + "choose \(name) and press Restore."),
                         backup: backup, message: detail)
        }

        do {
            let restart = try deps.runner.run("/usr/bin/killall", arguments: ["Dock"])
            guard restart.status == 0 else {
                return attention("The new order was saved but the Dock could not be restarted (\(restart.stderr)).")
            }
        } catch {
            return attention("The new order was saved but the Dock could not be restarted (\(error.localizedDescription)).")
        }

        var waited: TimeInterval = 0
        while true {
            if let live = try? deps.readLiveOrder(), matches(plan, live) {
                return RepairResult(outcome: .repaired, backup: backup,
                                    message: "The Space order was repaired. Backup saved as \(name).")
            }
            if waited >= deps.verifyTimeout { break }
            await deps.sleep(deps.pollInterval)
            waited += deps.pollInterval
        }
        return attention("The order did not match after the Dock restarted.")
    }

    private static func matches(_ plan: RepairPlan, _ live: [String: [String]]) -> Bool {
        plan.reorders.allSatisfy { item in
            live.first(where: { same($0.key, item.displayID) })?.value == item.desiredUUIDs
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
}
