import AppKit
import Foundation
import WMCore
import os

/// Applies the pin rules: a window that a rule matches is moved to its Desktop once, after it appears.
///
/// Every second it lists the windows (`WindowListReader`, cheap) and diffs the ids. Only new windows whose app
/// has a rule are looked up further (titles and Spaces, `WindowCatalog`, off the main actor). A window waits
/// for a title or a Space when it has none yet, and for the quiet period after a manual move; the matcher
/// (`PinRules.decide`) makes the call and `SpaceMover.moveAsync` does the move. Failures are logged.
///
/// Polling only runs while at least one rule exists. Windows that are already open when polling starts
/// are never pinned: rules apply to windows that are created afterwards.
@MainActor
final class PinWatcher {
    private static let logger = Logger(subsystem: AppInfo.bundleID, category: "pins")

    /// A new window that is still waiting after this many seconds is dropped.
    static let pendingLifetime: TimeInterval = 30

    private let store: PinRulesStore
    private let clock: @Sendable () -> Date
    private let interval: Duration
    private let quietPeriod: TimeInterval

    private(set) var rules: [PinRule] = []
    private var pollTask: Task<Void, Never>?
    /// Every window id seen while polling; a window in here is not new any more.
    private var known: Set<UInt32> = []
    private var pending: [UInt32: PendingWindow] = [:]
    /// Last Space seen for each pending window, to tell a manual move from no change.
    private var lastSpace: [UInt32: UInt64] = [:]
    private var manualMoves: [UInt32: Date] = [:]
    /// Windows this watcher already moved (each window is pinned at most once).
    private var alreadyMoved: Set<UInt32> = []

    private struct PendingWindow {
        var info: PinWindowInfo
        var firstSeen: Date
    }

    /// What one tick reads off the main actor. Built and read once, on either side of the hop, never shared.
    private struct Snapshot: @unchecked Sendable {
        var catalog: [CatalogWindow]
        var displays: [DisplaySpaces]?
    }

    var isPolling: Bool { pollTask != nil }

    /// - Parameters:
    ///   - store: where the rules are saved; tests pass one in a temporary folder.
    ///   - clock: the time source for the quiet period and the pending lifetime.
    ///   - interval: time between two polls (1 s in the app).
    ///   - quietPeriod: seconds after a manual move during which a window is left alone.
    init(store: PinRulesStore = PinRulesStore(), clock: @escaping @Sendable () -> Date = { Date() },
         interval: Duration = .seconds(1), quietPeriod: TimeInterval = 10) {
        self.store = store
        self.clock = clock
        self.interval = interval
        self.quietPeriod = quietPeriod
    }

    /// Reads the rules from disk and starts or stops polling. Call it at launch and after every change to the rules.
    func reload() {
        rules = store.load()
        guard !rules.isEmpty else {
            stop()
            return
        }
        guard pollTask == nil else { return }
        // Windows that exist now were not created by a rule, so they are known and never pinned.
        known = Set(WindowListReader.windows().map(\.windowID))
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.interval ?? .seconds(1))
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    /// Stops polling and forgets all window state.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        known = []
        pending = [:]
        lastSpace = [:]
        manualMoves = [:]
        alreadyMoved = []
    }

    // MARK: Polling

    private func tick() async {
        let now = clock()
        let current = Set(WindowListReader.windows().map(\.windowID))
        known.formIntersection(current)
        pending = pending.filter { current.contains($0.key) }
        lastSpace = lastSpace.filter { current.contains($0.key) }
        manualMoves = manualMoves.filter { current.contains($0.key) }
        alreadyMoved.formIntersection(current)

        let fresh = current.subtracting(known)
        known.formUnion(fresh)
        guard !fresh.isEmpty || !pending.isEmpty else { return }

        let snapshot = await Task.detached(priority: .utility) { () -> Snapshot in
            Snapshot(catalog: WindowCatalog.all(), displays: try? SpaceReader.displays())
        }.value
        let byID = Dictionary(snapshot.catalog.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })

        adopt(fresh, byID: byID, now: now)
        for id in Array(pending.keys) {
            guard let window = byID[id] else { continue }
            if let title = window.title { pending[id]?.info.title = title }
            pending[id]?.info.currentSpaceID = Self.singleSpace(window.spaceIDs)
        }
        guard !pending.isEmpty else { return }
        guard var displays = snapshot.displays else {
            Self.logger.error("pins: could not read the Desktops; \(self.pending.count) window(s) wait")
            return
        }
        displays = Self.withLiveMainDisplay(displays)

        for id in pending.keys.sorted() {
            guard let entry = pending[id] else { continue }
            if now.timeIntervalSince(entry.firstSeen) > Self.pendingLifetime {
                pending[id] = nil
                continue
            }
            // A Space change we did not make is a manual move. The matcher leaves such a window alone for a while.
            let space = entry.info.currentSpaceID
            if let space, let previous = lastSpace[id], previous != space, !alreadyMoved.contains(id) {
                manualMoves[id] = now
            }
            if let space { lastSpace[id] = space }

            let history = PinHistory(now: now, manualQuietPeriod: quietPeriod,
                                     manualMoveTimes: manualMoves, alreadyMoved: alreadyMoved)
            if let decision = PinRules.decide(newWindow: entry.info, rules: rules, spaces: displays, history: history) {
                pending[id] = nil
                alreadyMoved.insert(id)
                await perform(decision)
            } else if space == nil || entry.info.title == nil || history.isInQuietPeriod(id) {
                // The answer may change later: keep waiting.
                continue
            } else {
                pending[id] = nil
            }
        }
    }

    /// Adds the new windows whose app has a rule to the pending list.
    private func adopt(_ fresh: Set<UInt32>, byID: [UInt32: CatalogWindow], now: Date) {
        for id in fresh.sorted() {
            guard let window = byID[id],
                  let bundle = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier,
                  rules.contains(where: { $0.bundleID.caseInsensitiveCompare(bundle) == .orderedSame })
            else { continue }
            let space = Self.singleSpace(window.spaceIDs)
            pending[id] = PendingWindow(
                info: PinWindowInfo(bundleID: bundle, title: window.title, windowID: id, currentSpaceID: space),
                firstSeen: now)
            if let space { lastSpace[id] = space }
        }
    }

    private func perform(_ decision: PinDecision) async {
        let outcome = await SpaceMover.moveAsync(windowIDs: [decision.windowID], toSpace: decision.targetSpaceID)
        if outcome.success {
            lastSpace[decision.windowID] = decision.targetSpaceID
            Self.logger.info("pins: moved window \(decision.windowID) to Space \(decision.targetSpaceID) (rule \(decision.ruleID.uuidString, privacy: .public))")
        } else {
            let tried = outcome.attempts.filter(\.invoked).map { $0.method.rawValue }.joined(separator: ", ")
            Self.logger.error("pins: could not move window \(decision.windowID) to Space \(decision.targetSpaceID) (tried \(tried, privacy: .public))")
        }
    }

    // MARK: Helpers

    /// The one Space of a window; nil when it is on none or on several (all Desktops).
    private static func singleSpace(_ spaces: [UInt64]) -> UInt64? {
        spaces.count == 1 ? spaces[0] : nil
    }

    /// SkyLight may name the main display "Main"; rules store the display UUID, so use the UUID here too.
    private static func withLiveMainDisplay(_ displays: [DisplaySpaces]) -> [DisplaySpaces] {
        guard displays.contains(where: { $0.displayIdentifier == "Main" }),
              let uuid = DisplayMap.current().first(where: \.isMain)?.uuid else { return displays }
        return displays.map { display in
            var copy = display
            if copy.displayIdentifier == "Main" { copy.displayIdentifier = uuid }
            return copy
        }
    }
}
