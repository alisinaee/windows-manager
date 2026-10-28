import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// The restore engine (phase P2.8): "one click restores the profile".
//
// One run:
//   scan (WorkspaceScanner) -> match monitors and remap every saved frame onto its live monitor
//   -> match windows (WindowMatcher, on the remapped snapshots) -> plan (RestorePlanner)
//   -> launch apps that are not running -> if anything launched: scan, match and plan again
//   -> run the plan phase by phase -> settle: wait about a second, read the moved frames again and set a frame
//   once more when a window drifted (Electron apps resize themselves) -> report.
//
// A failing step is recorded and the run goes on. Task cancellation stops the run between steps; what was done
// is in the report. Every step has a timeout. Everything the engine does to the system goes through
// `RestoreEnvironment`, so tests run the whole engine against a fake.

// MARK: - Environment

/// A window the engine can act on. Fakes leave `element` nil.
public struct WindowHandle: @unchecked Sendable {
    public let windowID: UInt32
    public let pid: Int32
    public let element: AXElement?

    public init(windowID: UInt32, pid: Int32, element: AXElement? = nil) {
        self.windowID = windowID
        self.pid = pid
        self.element = element
    }
}

/// The outcome of one call into the environment.
public struct RestoreActionResult: Equatable, Sendable {
    public var succeeded: Bool
    /// Why it failed, or a remark about a success ("minimum size reached").
    public var detail: String?
    /// The frame read back (frame changes only).
    public var frame: CGRect?

    public init(succeeded: Bool, detail: String? = nil, frame: CGRect? = nil) {
        self.succeeded = succeeded
        self.detail = detail
        self.frame = frame
    }

    public static func ok(_ detail: String? = nil, frame: CGRect? = nil) -> RestoreActionResult {
        RestoreActionResult(succeeded: true, detail: detail, frame: frame)
    }

    public static func failure(_ detail: String, frame: CGRect? = nil) -> RestoreActionResult {
        RestoreActionResult(succeeded: false, detail: detail, frame: frame)
    }
}

/// An app to open and how many windows to wait for.
public struct LaunchRequest: Equatable, Sendable {
    public var app: AppRef
    public var minWindows: Int
    /// Per-app launcher options from the launch order (timeout, activation). Nil: the launcher defaults with
    /// `minWindows`. Fake environments ignore it.
    public var options: LaunchOptions?
    /// Seconds the engine waits after this app before the next one (sequential launch only; the engine does the
    /// waiting, the environment never sees it).
    public var delayAfter: TimeInterval

    public init(app: AppRef, minWindows: Int, options: LaunchOptions? = nil, delayAfter: TimeInterval = 0) {
        self.app = app
        self.minWindows = minWindows
        self.options = options
        self.delayAfter = delayAfter
    }
}

/// Adds one Desktop to a monitor (opt-in, `RestoreEngine.Configuration.addMissingDesktops`). The default
/// implementation, `MissionControlDesktopAdder`, drives Mission Control; tests inject a fake. It returns the
/// number of Desktops the monitor has after the add, re-read from the Spaces.
@MainActor
public protocol DesktopAdding {
    func addDesktop(on display: DisplayIdentity) async throws -> Int
}

/// Adds Desktops through `MissionControlDriver.addDesktop(displayIndex:)`, then re-reads the Spaces with
/// `SpaceReader` and returns the new Desktop count. Intrusive: it opens Mission Control on the Mac.
@MainActor
public final class MissionControlDesktopAdder: DesktopAdding {
    public init() {}

    public func addDesktop(on display: DisplayIdentity) async throws -> Int {
        let index = try Self.displayIndex(for: display)
        try MissionControlDriver().addDesktop(displayIndex: index)
        let displays = try SpaceReader.displays()
        guard displays.indices.contains(index) else {
            throw MissionControlError.verificationFailed("the display list changed while adding a Desktop")
        }
        return displays[index].spaces.filter { $0.kind == .desktop }.count
    }

    /// The 0-based position of the monitor in `SpaceReader.displays()`: by UUID, or "Main" for the main monitor.
    static func displayIndex(for display: DisplayIdentity) throws -> Int {
        let displays = try SpaceReader.displays()
        if let index = displays.firstIndex(where: { $0.displayIdentifier.caseInsensitiveCompare(display.uuid) == .orderedSame }) {
            return index
        }
        if display.isMain, let index = displays.firstIndex(where: { $0.displayIdentifier == "Main" }) {
            return index
        }
        throw MissionControlError.displayNotFound("\(display.name) is not in the list of displays SkyLight reports")
    }
}

/// Moves a window to another Desktop. The default implementation (`SystemSpaceMover`) calls `SpaceMover.move`
/// and reads the window's Space back; P3.2 can offer another one (for example one that adds Desktops first).
@MainActor
public protocol SpaceMoving {
    func move(windowID: UInt32, toSpace spaceID: UInt64) async -> RestoreActionResult
}

/// `SpaceMover.move` with its read-back: success means the window was seen on the target Space.
public struct SystemSpaceMover: SpaceMoving {
    public nonisolated init() {}

    public func move(windowID: UInt32, toSpace spaceID: UInt64) async -> RestoreActionResult {
        // Off the main actor: the move polls the window server for seconds, and the engine's step timeout must still fire.
        let outcome = await SpaceMover.moveAsync(windowIDs: [windowID], toSpace: spaceID)
        if outcome.alreadyOnTarget { return .ok("already on that Desktop") }
        if let method = outcome.succeededWith {
            return .ok("moved (\(method.rawValue)\(outcome.attempts.last?.late == true ? ", late" : ""))")
        }
        let tried = outcome.attempts.filter(\.invoked).map { $0.method.rawValue }
        let detail = tried.isEmpty
            ? "no way to move windows between Desktops is available on this Mac"
            : "the window was not on the target Desktop after the move (tried \(tried.joined(separator: ", ")))"
        return .failure(detail)
    }
}

/// Everything the engine does to the system. All calls happen on the main actor, one at a time.
@MainActor
public protocol RestoreEnvironment: AnyObject {
    /// Reads monitors, Spaces and windows.
    func scan() async -> WorkspaceScan
    /// Opens apps and waits until they have their windows. Results are in the order of `requests`.
    func launchAll(_ requests: [LaunchRequest]) async -> [LaunchResult]
    /// The Accessibility element of a window, also for windows on other Spaces. Nil when it cannot be reached.
    func element(for target: RestoreTarget) async -> WindowHandle?
    /// Places the window and reads the result back.
    func setFrame(_ handle: WindowHandle, to frame: CGRect) async -> RestoreActionResult
    /// Turns full screen on or off and waits until the window has arrived (or `timeout` seconds pass).
    func setFullScreen(_ handle: WindowHandle, _ on: Bool, timeout: TimeInterval) async -> RestoreActionResult
    func minimize(_ handle: WindowHandle) async -> RestoreActionResult
    func unminimize(_ handle: WindowHandle) async -> RestoreActionResult
    /// Brings the window to the front of its app and the app to the front.
    func raise(_ handle: WindowHandle, app: AppRef) async -> RestoreActionResult
    func moveToDesktop(windowID: UInt32, spaceID: UInt64) async -> RestoreActionResult
    func hideApp(pid: Int32, app: AppRef) async -> RestoreActionResult
    /// The frame now, for the settle check. Nil when unreadable.
    func frameOf(_ handle: WindowHandle) async -> CGRect?
    /// Waits. The engine uses it for the settle delay; fakes return at once.
    func sleep(_ seconds: TimeInterval) async
}

public extension RestoreEnvironment where Self == LiveRestoreEnvironment {
    /// The real thing: WorkspaceScanner, AppLauncher, WindowMover, AXRemoteWindows, SpaceMover.
    nonisolated static var live: LiveRestoreEnvironment { LiveRestoreEnvironment() }
}

// MARK: - Progress

/// What the engine reports while it runs.
public enum RestoreProgress: Sendable {
    case scanning
    case planned(RestorePlan)
    case launching([AppRef])
    case rescanning
    case stepStarted(index: Int, total: Int, description: String)
    case stepFinished(index: Int, total: Int, description: String, status: RestoreStepStatus, elapsed: TimeInterval)
    case settling
    case finished(RestoreReport)

    /// A line for logs and the command line.
    public var message: String {
        switch self {
        case .scanning:
            return "Scanning monitors, Spaces and windows"
        case .planned(let plan):
            return "Plan: \(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s"), "
                + "\(plan.unmatched.count) window\(plan.unmatched.count == 1 ? "" : "s") not found"
        case .launching(let apps):
            return "Launching " + apps.map(\.name).joined(separator: ", ")
        case .rescanning:
            return "Scanning again after launching"
        case .stepStarted(let index, let total, let description):
            return "[\(index)/\(total)] \(description)"
        case .stepFinished(let index, let total, let description, let status, let elapsed):
            return "[\(index)/\(total)] \(description) -> \(status.text) (\(String(format: "%.2f", elapsed)) s)"
        case .settling:
            return "Waiting for windows to settle"
        case .finished(let report):
            return report.summary
        }
    }
}

// MARK: - Engine

@MainActor
public final class RestoreEngine {
    public struct Configuration: Equatable, Sendable {
        /// Seconds one step may take before it counts as failed.
        public var stepTimeout: TimeInterval = 10
        /// Seconds a window may take to enter or leave full screen. The step timeout for those steps is this plus 5.
        public var fullScreenTimeout: TimeInterval = 8
        /// Step timeout for moving a window to another Desktop (SpaceMover tries several ways, each with a read-back).
        public var moveTimeout: TimeInterval = 20
        /// Seconds to wait before the frames are read again.
        public var settleDelay: TimeInterval = 1
        /// A frame within this many points of the wanted one is fine.
        public var frameTolerance: CGFloat = 2
        /// Opt-in (default off): add the Desktops a profile needs on a monitor that has fewer, before the moves.
        /// Never removes a Desktop; at most `RestorePlanner.maxAddedDesktopsPerRun` are added per run.
        public var addMissingDesktops = false
        /// Seconds one "add a Desktop" may take before the step counts as failed.
        public var addDesktopTimeout: TimeInterval = 30

        public init() {}
    }

    public let environment: any RestoreEnvironment
    public var configuration: Configuration
    public let desktopAdder: any DesktopAdding
    /// Where limits learned from clamped sizes go: the app cache and the profile. Nil: not kept (tests).
    public let sizeLimitStore: SizeLimitStore?
    public let profileStore: ProfileStore?

    /// `persistLearnedLimits` nil: kept only with the live environment.
    public init(environment: any RestoreEnvironment = .live, configuration: Configuration = Configuration(),
                desktopAdder: (any DesktopAdding)? = nil, persistLearnedLimits: Bool? = nil,
                sizeLimitStore: SizeLimitStore? = nil, profileStore: ProfileStore? = nil) {
        self.environment = environment
        self.configuration = configuration
        let persist = persistLearnedLimits ?? (environment is LiveRestoreEnvironment)
        self.sizeLimitStore = persist ? (sizeLimitStore ?? .shared) : nil
        self.profileStore = persist ? (profileStore ?? ProfileStore()) : nil
        self.desktopAdder = desktopAdder ?? MissionControlDesktopAdder()
    }

    // MARK: Run

    /// Restores `profile`. With `dryRun` it only scans, matches and plans: nothing is launched, moved or hidden,
    /// and every planned step is reported as skipped. Cancel the surrounding task to stop between steps.
    public func run(_ profile: Profile, dryRun: Bool = false,
                    progress: ((RestoreProgress) -> Void)? = nil) async -> RestoreReport {
        let state = RunState(profile: profile, dryRun: dryRun, progress: progress)

        emit(state, .scanning)
        var scan = await environment.scan()
        state.scanNotes = scan.notes
        state.lastScan = scan
        var plan = evaluate(profile, scan: scan, addingDesktops: addsDesktops(for: profile))
        emit(state, .planned(plan))
        state.totalSteps = plan.steps.count

        if dryRun {
            for step in plan.steps { recordSkipped(step, reason: "dry run", state: state) }
            return finish(state, plan: plan)
        }

        // Launch apps that are not running.
        let launchSteps = plan.steps(in: .launch)
        var launchResults: [LaunchResult] = []
        var planAgain = false
        if !launchSteps.isEmpty {
            if Task.isCancelled {
                state.cancelled = true
                for step in plan.steps { recordSkipped(step, reason: "cancelled", state: state) }
                return finish(state, plan: plan)
            }
            launchResults = await runLaunch(launchSteps, state: state)
            plan = plan.removing(.launch)
            if !Task.isCancelled, launchResults.contains(where: { $0.status == .launched || $0.status == .timedOut }) {
                planAgain = true
            }
        }

        // Opt-in: add the missing Desktops. They run before the moves; the moves need the new Desktops' ids, so the
        // plan is made again afterwards (and then no longer asks for adds, so a failed add is reported once).
        let addSteps = plan.steps(in: .addDesktop)
        if !addSteps.isEmpty {
            if Task.isCancelled {
                for step in addSteps { recordSkipped(step, reason: "cancelled", state: state) }
            } else {
                for step in addSteps { await execute(step, state: state) }
                planAgain = true
            }
            plan = plan.removing(.addDesktop)
        }

        if planAgain, !Task.isCancelled {
            emit(state, .rescanning)
            scan = await environment.scan()
            state.scanNotes = scan.notes
            state.lastScan = scan
            state.handles.removeAll()
            state.unreachable.removeAll()
            plan = evaluate(profile, scan: scan, addingDesktops: false).removing(.launch)
            emit(state, .planned(plan))
        }
        state.totalSteps = launchSteps.count + addSteps.count + plan.steps.count
        Self.explainLaunchFailures(in: &plan, results: launchResults)

        // The plan, phase by phase.
        let steps = plan.steps
        for (offset, step) in steps.enumerated() {
            if Task.isCancelled {
                state.cancelled = true
                for rest in steps[offset...] { recordSkipped(rest, reason: "cancelled", state: state) }
                break
            }
            await execute(step, state: state)
        }

        // Settle: Electron apps resize themselves a moment after they were placed.
        if Task.isCancelled {
            state.cancelled = true
        } else if !state.placed.isEmpty {
            await settle(state: state)
        }
        return finish(state, plan: plan)
    }

    /// The engine-level flag or the profile's own option: either one enables adding Desktops.
    private func addsDesktops(for profile: Profile) -> Bool {
        configuration.addMissingDesktops || profile.options.addMissingDesktops
    }

    // MARK: Preview

    /// The plan a run would make now, without doing anything: one `scan` of the environment, then matching and
    /// planning. Nothing is launched, moved, hidden or sleeping. For the map's dry run and compare overlay.
    public func preview(profile: Profile) async -> RestorePlan {
        let scan = await environment.scan()
        return evaluate(profile, scan: scan, addingDesktops: addsDesktops(for: profile))
    }

    // MARK: Evaluate

    /// Monitors, window matching and planning for one scan.
    private func evaluate(_ profile: Profile, scan: WorkspaceScan, addingDesktops: Bool) -> RestorePlan {
        let displayMatch = DisplayMap.match(saved: profile.displays, current: scan.displays)
        let snapshots = RestorePlanner.remap(profile.windows, savedDisplays: profile.displays, displayMatch: displayMatch)
        let match = WindowMatcher.match(snapshots: snapshots, live: scan.windows)
        return RestorePlanner.plan(profile: profile, scan: scan, displayMatch: displayMatch, match: match,
                                   options: profile.options, addMissingDesktops: addingDesktops)
    }

    /// Replaces "will be launched" in the unmatched list by what really happened to the app.
    static func explainLaunchFailures(in plan: inout RestorePlan, results: [LaunchResult]) {
        guard !results.isEmpty else { return }
        for index in plan.unmatched.indices {
            guard let result = results.first(where: { Profile.isSameApp($0.app, plan.unmatched[index].app) }) else { continue }
            switch result.status {
            case .alreadyRunning:
                plan.unmatched[index].reason = "the app has fewer windows open than the profile"
            case .launched:
                plan.unmatched[index].reason = "the app was launched, but it opened fewer windows than the profile"
            case .notFound:
                plan.unmatched[index].reason = "the app could not be found on this Mac"
            case .failed(let message):
                plan.unmatched[index].reason = "the app could not be launched: \(message)"
            case .timedOut:
                plan.unmatched[index].reason = "the app did not open its windows in time"
            }
        }
    }

    // MARK: Launch

    private func runLaunch(_ steps: [RestoreStep], state: RunState) async -> [LaunchResult] {
        if let plan = state.profile.launchPlan, plan.mode == .sequential {
            return await runSequentialLaunch(steps, plan: plan, state: state)
        }
        var requests: [LaunchRequest] = []
        for step in steps {
            if case .launch(let app, let count) = step { requests.append(LaunchRequest(app: app, minWindows: count)) }
        }
        emit(state, .launching(requests.map(\.app)))
        var indexes: [Int] = []
        for step in steps {
            let index = state.nextIndex
            state.nextIndex += 1
            indexes.append(index)
            emit(state, .stepStarted(index: index, total: state.totalSteps, description: step.description))
        }

        let results = await environment.launchAll(requests)

        for (offset, step) in steps.enumerated() {
            recordLaunch(step, result: offset < results.count ? results[offset] : nil, index: indexes[offset], state: state)
        }
        return results
    }

    /// Sequential launch order: one app at a time in the order of the steps (the planner already put them in
    /// `LaunchSequence.order`), each waiting for its own condition and timeout, then its `delayAfter`.
    /// A failed or timed-out app is a failed step and the sequence goes on; cancellation skips the rest.
    private func runSequentialLaunch(_ steps: [RestoreStep], plan: LaunchPlan, state: RunState) async -> [LaunchResult] {
        let sequence = LaunchSequence.order(state.profile)
        emit(state, .launching(steps.compactMap { if case .launch(let app, _) = $0 { return app } else { return nil } }))
        var results: [LaunchResult] = []
        for (offset, step) in steps.enumerated() {
            guard case .launch(let app, let count) = step else { continue }
            if Task.isCancelled {
                state.cancelled = true
                for rest in steps[offset...] { recordSkipped(rest, reason: "cancelled", state: state) }
                break
            }
            let item = sequence.first { Profile.isSameApp($0.app, app) }
            let activates = plan.items.first { $0.enabled && Profile.isSameApp($0.app, app) }?.activates ?? false
            let options = LaunchOptions(minWindows: count, timeout: item?.timeout ?? LaunchOptions.defaultTimeout,
                                        activates: activates)
            let request = LaunchRequest(app: app, minWindows: count, options: options, delayAfter: item?.delayAfter ?? 0)

            let index = state.nextIndex
            state.nextIndex += 1
            emit(state, .stepStarted(index: index, total: state.totalSteps, description: step.description))
            let result = await environment.launchAll([request]).first
            recordLaunch(step, result: result, index: index, state: state)
            if let result { results.append(result) }

            // Give the app time to finish starting up before the next one. An app that was already running needed
            // none, and neither does the end of the list.
            let isLast = offset == steps.count - 1
            if let result, result.status != .alreadyRunning, result.isRunning || result.status == .timedOut,
               request.delayAfter > 0, !isLast, !Task.isCancelled {
                await environment.sleep(request.delayAfter)
            }
        }
        return results
    }

    /// Writes the outcome of one launch step into the report and the progress.
    private func recordLaunch(_ step: RestoreStep, result: LaunchResult?, index: Int, state: RunState) {
        guard case .launch(let app, let count) = step else { return }
        let status: RestoreStepStatus
        var note: String?
        var text = "failed: the launcher returned no result"
        var launched = false
        var windowCount = 0
        var elapsed: TimeInterval = 0
        if let result {
            elapsed = result.timings.total
            windowCount = result.windowCount
            switch result.status {
            case .launched:
                status = .done
                launched = true
                text = "launched"
                note = count == 0 ? "app ready" : "\(result.windowCount) of \(count) window\(count == 1 ? "" : "s") ready"
            case .alreadyRunning:
                status = .skipped("already running")
                text = "already running"
            case .notFound:
                status = .failed("the app could not be found on this Mac")
                text = "not found"
            case .failed(let message):
                status = .failed(message)
                text = "failed: \(message)"
            case .timedOut:
                status = .failed("timed out waiting for \(count) window\(count == 1 ? "" : "s")")
                text = "timed out"
            }
        } else {
            status = .failed("the launcher returned no result")
        }
        state.report.launched.append(RestoreLaunchRecord(app: app, result: text, launched: launched,
                                                         windowCount: windowCount, elapsed: elapsed))
        let record = RestoreStepRecord(index: index, phase: .launch, kind: step.kind,
                                       description: step.description, app: app.name, status: status,
                                       elapsed: elapsed, note: note)
        state.report.steps.append(record)
        emit(state, .stepFinished(index: record.index, total: state.totalSteps, description: record.description,
                                  status: status, elapsed: elapsed))
    }

    // MARK: Steps

    /// What a step did, before it is written into the report.
    private struct Outcome {
        var status: RestoreStepStatus
        var note: String?
        var handle: WindowHandle?
        var frame: CGRect?
    }

    private func execute(_ step: RestoreStep, state: RunState) async {
        let index = state.nextIndex
        state.nextIndex += 1
        emit(state, .stepStarted(index: index, total: state.totalSteps, description: step.description))
        let started = Self.uptime()
        let outcome = await perform(step, state: state)
        let elapsed = Self.uptime() - started

        let record = RestoreStepRecord(index: index, phase: step.phase, kind: step.kind, description: step.description,
                                       snapshotID: step.target?.snapshotID, windowID: step.target?.windowID,
                                       app: step.app.name, status: outcome.status, elapsed: elapsed, note: outcome.note)
        state.report.steps.append(record)
        emit(state, .stepFinished(index: index, total: state.totalSteps, description: step.description,
                                  status: outcome.status, elapsed: elapsed))

        // Remember what the settle pass has to check.
        guard let target = step.target, outcome.status.isDone else { return }
        switch step {
        case .setFrame(_, let frame, let from, let beforeFullScreen):
            learn(frame: frame, from: from, actual: outcome.frame, target: target, state: state)
            if !beforeFullScreen, let handle = outcome.handle {
                // A window that clamps its size keeps that size; it is the one to check later.
                var expected = frame
                if case .sizeClamped(let size) = SizeLimitLearning.classify(
                    requested: frame, actual: outcome.frame, sizeTolerance: configuration.frameTolerance) {
                    expected = CGRect(origin: frame.origin, size: size)
                }
                state.placed[target.snapshotID] = Placed(target: target, handle: handle, frame: expected)
                if !state.placedOrder.contains(target.snapshotID) { state.placedOrder.append(target.snapshotID) }
            }
        case .enterFullScreen, .minimize:
            // Full-screen and minimized windows do not keep the frame; nothing to check.
            state.placed[target.snapshotID] = nil
        default:
            break
        }
    }

    /// Notes what a clamped size says about the window, to be stored when the run finishes.
    private func learn(frame: CGRect, from: CGRect, actual: CGRect?, target: RestoreTarget, state: RunState) {
        guard case .sizeClamped(let size) = SizeLimitLearning.classify(requested: frame, actual: actual),
              let learned = SizeLimitLearning.learn(requested: frame.size, observed: size, previous: from.size)
        else { return }
        state.learned[target.snapshotID] = LearnedLimits(
            target: target, limits: SizeLimitLearning.merge(state.learned[target.snapshotID]?.limits, with: learned) ?? learned)
    }

    /// Writes the learned limits into the app cache and into the profile's window entries (merged).
    private func persistLearned(_ state: RunState) {
        guard !state.learned.isEmpty else { return }
        for item in state.learned.values {
            sizeLimitStore?.record(item.limits, bundleID: item.target.app.bundleID, title: item.target.title)
        }
        guard let profileStore, var profile = try? profileStore.load(state.profile.id) else { return }
        var changed = false
        for (id, item) in state.learned {
            guard let i = profile.windows.firstIndex(where: { $0.id == id }) else { continue }
            let merged = SizeLimitLearning.merge(profile.windows[i].resizeLimits, with: item.limits)
            if SizeLimitLearning.adds(merged, to: profile.windows[i].resizeLimits) {
                profile.windows[i].resizeLimits = merged
                changed = true
            }
        }
        if changed { _ = try? profileStore.save(profile) }
    }

    private func perform(_ step: RestoreStep, state: RunState) async -> Outcome {
        let environment = self.environment
        let config = configuration
        switch step {
        case .launch:
            return Outcome(status: .skipped("apps are launched before the other steps"))

        case .exitFullScreen(let target):
            let seconds = config.fullScreenTimeout
            return await onWindow(target, state: state, timeout: seconds + 5) { handle in
                await environment.setFullScreen(handle, false, timeout: seconds)
            }

        case .unminimize(let target):
            return await onWindow(target, state: state, timeout: config.stepTimeout) { handle in
                await environment.unminimize(handle)
            }

        case .addDesktop(let display, let count):
            return await addDesktops(on: display, count: count, state: state)

        case .moveToDesktop(let target, _, let spaceID, _, _, _):
            return await limited(timeout: config.moveTimeout) {
                await environment.moveToDesktop(windowID: target.windowID, spaceID: spaceID)
            }

        case .setFrame(let target, let frame, _, _):
            return await onWindow(target, state: state, timeout: config.stepTimeout) { handle in
                await environment.setFrame(handle, to: frame)
            }

        case .enterFullScreen(let target, _, _, _):
            let seconds = config.fullScreenTimeout
            return await onWindow(target, state: state, timeout: seconds + 5) { handle in
                await environment.setFullScreen(handle, true, timeout: seconds)
            }

        case .minimize(let target):
            return await onWindow(target, state: state, timeout: config.stepTimeout) { handle in
                await environment.minimize(handle)
            }

        case .raise(let target, _):
            return await onWindow(target, state: state, timeout: config.stepTimeout) { handle in
                await environment.raise(handle, app: target.app)
            }

        case .hideApp(let app, let pid):
            return await limited(timeout: config.stepTimeout) {
                await environment.hideApp(pid: pid, app: app)
            }

        case .needsConfirmationQuit(let app, _):
            state.report.needsConfirmation.append(app)
            return Outcome(status: .skipped("needs confirmation"))
        }
    }

    /// Adds `count` Desktops to `display`, one at a time. After each add the count must have grown; a failed or
    /// unverified add fails this step only. Never more than `RestorePlanner.maxAddedDesktopsPerRun` in a run.
    private func addDesktops(on display: DisplayIdentity, count: Int, state: RunState) async -> Outcome {
        let adder = desktopAdder
        let timeout = configuration.addDesktopTimeout
        var known = state.lastScan?.spaces(onDisplay: display.uuid)?.desktops.count ?? 0
        var added = 0
        func outcome(_ status: RestoreStepStatus) -> Outcome {
            let note = added > 0 ? "added \(added); \(display.name) has \(known) Desktop\(known == 1 ? "" : "s") now" : nil
            return Outcome(status: status, note: note)
        }
        for _ in 0..<max(count, 0) {
            guard state.desktopsAdded < RestorePlanner.maxAddedDesktopsPerRun else {
                return outcome(.failed("the limit of \(RestorePlanner.maxAddedDesktopsPerRun) added Desktops per run is reached"))
            }
            let attempt = await StepRace<DesktopAddAttempt>().run(timeout: timeout) {
                do {
                    return .count(try await adder.addDesktop(on: display))
                } catch {
                    return .error(error.localizedDescription)
                }
            }
            switch attempt {
            case nil:
                return outcome(.failed("adding a Desktop to \(display.name) timed out after \(Self.format(timeout)) s"))
            case .error(let message)?:
                return outcome(.failed("could not add a Desktop to \(display.name): \(message)"))
            case .count(let now)?:
                guard now > known else {
                    return outcome(.failed("\(display.name) still has \(now) Desktop\(now == 1 ? "" : "s") after the add (it had \(known))"))
                }
                known = now
                added += 1
                state.desktopsAdded += 1
            }
        }
        return outcome(.done)
    }

    /// Runs `action` on the window's Accessibility element, within the timeout.
    private func onWindow(_ target: RestoreTarget, state: RunState, timeout: TimeInterval,
                          _ action: @escaping @MainActor (WindowHandle) async -> RestoreActionResult) async -> Outcome {
        // The lookup can take a while (it may search element ids), so it is raced against the timeout too.
        guard let lookup = await StepRace<WindowHandle?>().run(timeout: timeout, { [self] in
            await handle(for: target, state: state)
        }) else {
            return Outcome(status: .failed("looking up the window timed out after \(Self.format(timeout)) s"))
        }
        guard let handle = lookup else {
            return Outcome(status: .failed("window not reachable by Accessibility"))
        }
        var outcome = await limited(timeout: timeout) { await action(handle) }
        outcome.handle = handle
        return outcome
    }

    /// Runs `action` and turns its result into an outcome; a call that takes longer than `timeout` seconds is
    /// cancelled and counts as failed.
    private func limited(timeout: TimeInterval,
                         _ action: @escaping @MainActor () async -> RestoreActionResult) async -> Outcome {
        guard let result = await StepRace<RestoreActionResult>().run(timeout: timeout, action) else {
            return Outcome(status: .failed("timed out after \(Self.format(timeout)) s"))
        }
        if result.succeeded { return Outcome(status: .done, note: result.detail, frame: result.frame) }
        return Outcome(status: .failed(result.detail ?? "refused"), frame: result.frame)
    }

    private func handle(for target: RestoreTarget, state: RunState) async -> WindowHandle? {
        if let known = state.handles[target.windowID] { return known }
        if state.unreachable.contains(target.windowID) { return nil }
        guard let found = await environment.element(for: target) else {
            state.unreachable.insert(target.windowID)
            return nil
        }
        state.handles[target.windowID] = found
        return found
    }

    // MARK: Settle

    /// Waits, reads the frames of the windows that were placed, and sets a frame once more where a window drifted.
    private func settle(state: RunState) async {
        emit(state, .settling)
        await environment.sleep(configuration.settleDelay)
        let environment = self.environment
        let config = configuration
        for id in state.placedOrder {
            if Task.isCancelled {
                state.cancelled = true
                return
            }
            guard let placed = state.placed[id] else { continue }
            guard let actual = await environment.frameOf(placed.handle),
                  !WindowMover.frameMatches(actual, placed.frame, tolerance: config.frameTolerance) else { continue }

            let description = "set frame \(RestoreFormat.rect(placed.frame)) again (window drifted to "
                + "\(RestoreFormat.rect(actual))): \(placed.target.label)"
            let index = state.nextIndex
            state.nextIndex += 1
            state.totalSteps = max(state.totalSteps, index)
            emit(state, .stepStarted(index: index, total: state.totalSteps, description: description))
            let started = Self.uptime()
            let outcome = await limited(timeout: config.stepTimeout) {
                await environment.setFrame(placed.handle, to: placed.frame)
            }
            let elapsed = Self.uptime() - started
            state.report.steps.append(RestoreStepRecord(
                index: index, phase: .setFrame, kind: "reapplyFrame", description: description,
                snapshotID: placed.target.snapshotID, windowID: placed.target.windowID, app: placed.target.app.name,
                status: outcome.status, elapsed: elapsed, note: outcome.note))
            emit(state, .stepFinished(index: index, total: state.totalSteps, description: description,
                                      status: outcome.status, elapsed: elapsed))
        }
    }

    // MARK: Reporting

    private func recordSkipped(_ step: RestoreStep, reason: String, state: RunState) {
        let index = state.nextIndex
        state.nextIndex += 1
        state.report.steps.append(RestoreStepRecord(
            index: index, phase: step.phase, kind: step.kind, description: step.description,
            snapshotID: step.target?.snapshotID, windowID: step.target?.windowID, app: step.app.name,
            status: .skipped(reason)))
        if case .needsConfirmationQuit(let app, _) = step { state.report.needsConfirmation.append(app) }
    }

    private func finish(_ state: RunState, plan: RestorePlan) -> RestoreReport {
        var report = state.report
        report.cancelled = state.cancelled
        report.unmatched = plan.unmatched
        report.ambiguous = plan.ambiguous
        var warnings = plan.warnings
        for note in state.scanNotes where !warnings.contains(note) { warnings.append(note) }
        report.warnings = warnings
        report.finish(profile: state.profile, elapsed: Self.uptime() - state.started)
        persistLearned(state)
        emit(state, .finished(report))
        return report
    }

    private func emit(_ state: RunState, _ event: RestoreProgress) {
        state.progress?(event)
    }

    nonisolated static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    nonisolated static func format(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.2f", seconds)
    }

    // MARK: Run state

    private struct LearnedLimits {
        var target: RestoreTarget
        var limits: WindowResizeLimits
    }

    private struct Placed {
        var target: RestoreTarget
        var handle: WindowHandle
        var frame: CGRect
    }

    private final class RunState {
        let profile: Profile
        let dryRun: Bool
        let progress: ((RestoreProgress) -> Void)?
        var report: RestoreReport
        let started = RestoreEngine.uptime()
        var nextIndex = 1
        var totalSteps = 0
        var cancelled = false
        var scanNotes: [String] = []
        var handles: [UInt32: WindowHandle] = [:]
        var unreachable: Set<UInt32> = []
        /// The latest scan, for the Desktop counts the add steps start from.
        var lastScan: WorkspaceScan?
        /// Desktops added so far in this run (the safety cap).
        var desktopsAdded = 0
        /// Windows whose frame was set, to be checked again after the settle delay (by snapshot id).
        var placed: [UUID: Placed] = [:]
        var placedOrder: [UUID] = []
        /// Size limits seen this run, by snapshot id.
        var learned: [UUID: LearnedLimits] = [:]

        init(profile: Profile, dryRun: Bool, progress: ((RestoreProgress) -> Void)?) {
            self.profile = profile
            self.dryRun = dryRun
            self.progress = progress
            self.report = RestoreReport(profileID: profile.id, profileName: profile.name, dryRun: dryRun)
        }
    }
}

// MARK: - Timeout

/// What one "add a Desktop" call answered.
private enum DesktopAddAttempt: Sendable {
    /// The Desktop count of the monitor after the add.
    case count(Int)
    case error(String)
}

/// Runs one operation and gives up after a time limit. The operation runs in its own task, so a cancelled
/// engine does not interrupt a step half way; when the limit passes the task is cancelled and the caller
/// gets nil (an operation that never looks at cancellation still ends by itself later).
/// Only used from the main actor; the lock-free state is fine because every access happens there.
private final class StepRace<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T?, Never>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func run(timeout: TimeInterval, _ operation: @escaping @MainActor () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            self.continuation = continuation
            work = Task { @MainActor in
                let value = await operation()
                self.finish(value)
            }
            timer = Task { @MainActor in
                let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                if !Task.isCancelled { self.finish(nil) }
            }
        }
    }

    private func finish(_ value: T?) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        if value == nil { work?.cancel() }
        continuation.resume(returning: value)
    }
}

// MARK: - Live environment

/// The real environment: the window server, Accessibility, SkyLight.
@MainActor
public final class LiveRestoreEnvironment: RestoreEnvironment {
    private nonisolated(unsafe) let spaceMover: any SpaceMoving
    private let scanOptions: ScanOptions
    private var launcher: AppLauncher?

    public nonisolated init(spaceMover: any SpaceMoving = SystemSpaceMover(), scanOptions: ScanOptions = ScanOptions()) {
        self.spaceMover = spaceMover
        self.scanOptions = scanOptions
    }

    /// Serial queue for the blocking Accessibility and window-server work of this environment. The main actor is
    /// never held by it, so the menu keeps animating and the engine's step timeout can fire. Work that outlives
    /// its caller (after a timeout) keeps running; later work waits behind it.
    private static let workQueue = DispatchQueue(label: "WMCore.RestoreEnvironment.work")

    static func runOffMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            workQueue.async { continuation.resume(returning: work()) }
        }
    }

    private static func readBool(_ element: AXElement, _ attribute: String) async -> Bool? {
        await runOffMain { element.bool(attribute) }
    }

    private static func writeBool(_ element: AXElement, _ attribute: String, _ value: Bool) async -> Bool {
        await runOffMain { element.set(attribute, value).isSuccess }
    }

    public func scan() async -> WorkspaceScan {
        let options = scanOptions
        return await Self.runOffMain { WorkspaceScanner.scan(options: options) }
    }

    public func launchAll(_ requests: [LaunchRequest]) async -> [LaunchResult] {
        let launcher = self.launcher ?? AppLauncher()
        self.launcher = launcher
        return await launcher.launchAll(requests.map(\.app), optionsFor: { app in
            let wanted = requests.first { Profile.isSameApp($0.app, app) }?.minWindows ?? 1
            if var options = requests.first(where: { Profile.isSameApp($0.app, app) })?.options {
                options.minWindows = wanted
                return options
            }
            return LaunchOptions(minWindows: wanted)
        })
    }

    public func element(for target: RestoreTarget) async -> WindowHandle? {
        let windowID = target.windowID
        let pid = target.pid
        return await Self.runOffMain {
            AXRemoteWindows.element(forWindowID: windowID, pid: pid).map {
                WindowHandle(windowID: windowID, pid: pid, element: $0)
            }
        }
    }

    public func setFrame(_ handle: WindowHandle, to frame: CGRect) async -> RestoreActionResult {
        guard let element = handle.element else { return .failure("no Accessibility element") }
        // A window of a hidden app has to be shown again, otherwise the restore leaves it invisible.
        if let app = NSRunningApplication(processIdentifier: handle.pid), app.isHidden { app.unhide() }
        let result = await Self.runOffMain { WindowMover.setFrame(element, to: frame) }
        if result.matched { return .ok(frame: result.actual) }
        let now = result.actual.map { RestoreFormat.rect($0) } ?? "unreadable"
        if result.minSizeHit && !result.refused {
            return .ok("minimum size reached (now \(now))", frame: result.actual)
        }
        // The app took the position but kept another size (fixed or clamped): done, with a note.
        if case .sizeClamped(let size) = SizeLimitLearning.classify(requested: frame, actual: result.actual) {
            return .ok("\(SizeLimitLearning.note(for: size)) (now \(now))", frame: result.actual)
        }
        return .failure("the window refused the frame (now \(now))", frame: result.actual)
    }

    public func setFullScreen(_ handle: WindowHandle, _ on: Bool, timeout: TimeInterval) async -> RestoreActionResult {
        guard let element = handle.element else { return .failure("no Accessibility element") }
        let attribute = AXElement.fullScreenAttribute
        if await Self.readBool(element, attribute) == on { return .ok("already \(on ? "in" : "out of") full screen") }
        guard await Self.writeBool(element, attribute, on) else {
            return .failure("the app refused to \(on ? "enter" : "leave") full screen")
        }

        // 1. The attribute flips.
        let deadline = RestoreEngine.uptime() + timeout
        while await Self.readBool(element, attribute) != on {
            if Task.isCancelled || RestoreEngine.uptime() >= deadline {
                return .failure("the window did not \(on ? "enter" : "leave") full screen in time")
            }
            await sleep(0.05)
        }
        // 2. The Space change has finished: the window sits on a full-screen Space or on a Desktop.
        var arrived = Self.isOnExpectedSpace(windowID: handle.windowID, fullScreen: on)
        while !arrived, !Task.isCancelled, RestoreEngine.uptime() < deadline {
            await sleep(0.1)
            arrived = Self.isOnExpectedSpace(windowID: handle.windowID, fullScreen: on)
        }
        await sleep(0.3) // let the animation end before the next window is touched
        return arrived ? .ok() : .ok("full screen changed, but the new Space was not confirmed")
    }

    public func minimize(_ handle: WindowHandle) async -> RestoreActionResult {
        await setMinimized(handle, true)
    }

    public func unminimize(_ handle: WindowHandle) async -> RestoreActionResult {
        await setMinimized(handle, false)
    }

    private func setMinimized(_ handle: WindowHandle, _ on: Bool) async -> RestoreActionResult {
        guard let element = handle.element else { return .failure("no Accessibility element") }
        if await Self.readBool(element, kAXMinimizedAttribute) == on { return .ok() }
        guard await Self.writeBool(element, kAXMinimizedAttribute, on) else {
            return .failure("the app refused to \(on ? "minimize" : "unminimize") the window")
        }
        let deadline = RestoreEngine.uptime() + 1.5
        while await Self.readBool(element, kAXMinimizedAttribute) != on {
            if Task.isCancelled || RestoreEngine.uptime() >= deadline {
                return .failure("the window did not \(on ? "minimize" : "unminimize") in time")
            }
            await sleep(0.05)
        }
        await sleep(on ? 0.2 : 0.4) // the Dock animation
        return .ok()
    }

    public func raise(_ handle: WindowHandle, app: AppRef) async -> RestoreActionResult {
        guard let element = handle.element else { return .failure("no Accessibility element") }
        let raised = await Self.runOffMain({ element.perform(kAXRaiseAction) })
        if !raised.isSuccess {
            // A window that is already the app's main window needs no raise; the app only has to come forward.
            let alreadyMain = await Self.readBool(element, kAXMainAttribute) == true
            guard alreadyMain, raised == .actionUnsupported || raised == .cannotComplete else {
                return .failure("the window did not accept AXRaise (AXError \(raised.rawValue))")
            }
        }
        // AXRaise only orders the windows of one app; the app has to come forward too for the saved
        // stacking across apps. Failing to do so is not an error.
        let application = AXElement.application(pid: handle.pid)
        application.set(kAXFrontmostAttribute, true)
        return .ok()
    }

    public func moveToDesktop(windowID: UInt32, spaceID: UInt64) async -> RestoreActionResult {
        await spaceMover.move(windowID: windowID, toSpace: spaceID)
    }

    public func hideApp(pid: Int32, app: AppRef) async -> RestoreActionResult {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return .failure("never hides itself") }
        guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else {
            return .failure("the app is not running any more")
        }
        guard running.activationPolicy == .regular else { return .failure("not a regular app") }
        let identity = AppRef(bundleID: running.bundleIdentifier, name: running.localizedName ?? app.name)
        guard !RestorePlanner.isProtected(identity), !RestorePlanner.isProtected(app) else {
            return .failure("system apps are never hidden")
        }
        if running.isHidden { return .ok("already hidden") }
        guard running.hide() else { return .failure("the app did not accept the hide request") }
        let deadline = RestoreEngine.uptime() + 1
        while !running.isHidden {
            if Task.isCancelled || RestoreEngine.uptime() >= deadline { return .ok("hide requested, not confirmed") }
            await sleep(0.05)
        }
        return .ok()
    }

    public func frameOf(_ handle: WindowHandle) async -> CGRect? {
        guard let element = handle.element else { return nil }
        return await Self.runOffMain { element.frame }
    }

    public func sleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// True when the window is on a full-screen Space (`fullScreen`) or on a Desktop (otherwise).
    private static func isOnExpectedSpace(windowID: UInt32, fullScreen: Bool) -> Bool {
        let ids = SpaceReader.spaces(forWindows: [windowID])[windowID] ?? []
        guard !ids.isEmpty, let displays = try? SpaceReader.displays() else { return false }
        let wanted: SpaceKind = fullScreen ? .fullscreen : .desktop
        return displays.flatMap(\.spaces).contains { ids.contains($0.id) && $0.kind == wanted }
    }
}
