import Foundation

public enum StepStatus: String, Codable, Equatable, Sendable {
    case succeeded, failed, skipped, cancelled
}

public struct StepReport: Codable, Equatable, Sendable {
    public var index: Int
    public var summary: String
    public var status: StepStatus
    public var duration: TimeInterval
    public var error: String?
}

public struct ActionRunReport: Codable, Equatable, Sendable {
    public var actionID: UUID
    public var name: String
    public var steps: [StepReport]
    public var cancelled: Bool
    public var duration: TimeInterval

    /// True when no step failed (steps that were allowed to fail count as failed here too) and it was not cancelled.
    public var succeeded: Bool { !cancelled && !steps.contains { $0.status == .failed } }
    /// True when the action ran to the end, ignoring failures of optional steps.
    public var completed: Bool { !cancelled && !steps.contains { $0.status == .skipped || $0.status == .cancelled } }
}

/// Runs the steps of a ProfileAction in order. Never throws: problems end up in the report.
public struct ActionRunner: Sendable {
    public let ax: any AXProvider
    public let process: any ProcessRunner
    public let clock: any ActionClock

    public init(ax: any AXProvider, process: any ProcessRunner, clock: any ActionClock = SystemClock()) {
        self.ax = ax; self.process = process; self.clock = clock
    }

    public func run(_ action: ProfileAction) async -> ActionRunReport {
        let started = clock.now()
        var reports: [StepReport] = []
        var cancelled = false
        var stopped = !action.enabled
        for (index, step) in action.steps.enumerated() {
            if stopped || cancelled {
                reports.append(StepReport(index: index, summary: step.summary,
                                          status: cancelled ? .cancelled : .skipped, duration: 0, error: nil))
                continue
            }
            if Task.isCancelled {
                cancelled = true
                reports.append(StepReport(index: index, summary: step.summary, status: .cancelled, duration: 0, error: nil))
                continue
            }
            let t0 = clock.now()
            var status = StepStatus.succeeded
            var message: String?
            do {
                try await execute(step.unwrapped)
            } catch is CancellationError {
                status = .cancelled; cancelled = true
            } catch {
                status = .failed
                message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                if !step.continueOnFailure { stopped = true }
            }
            reports.append(StepReport(index: index, summary: step.summary, status: status,
                                      duration: max(0, clock.now() - t0), error: message))
        }
        return ActionRunReport(actionID: action.id, name: action.name, steps: reports, cancelled: cancelled,
                               duration: max(0, clock.now() - started))
    }

    // MARK: steps

    func execute(_ step: ActionStep) async throws {
        try Task.checkCancellation()
        switch step {
        case .launchApp(let bundleID):
            try await process.launchApp(bundleID: bundleID, timeout: step.timeout)
        case .press(let locator, let timeout):
            let node = try await locate(locator, containing: nil, timeout: timeout)
            if !node.press() { throw ActionError.pressFailed(locator.describe) }
        case .menu(let bundleID, let path):
            try await pressMenu(bundleID: bundleID, path: path, timeout: step.timeout)
        case .typeText(let text, let into):
            if let into {
                let node = try await locate(into, containing: nil, timeout: step.timeout)
                if !node.focus() { throw ActionError.failed("could not focus \(into.describe)") }
            }
            try ax.typeText(text)
        case .key(let combo):
            guard let parsed = KeyCombo.parse(combo) else { throw ActionError.invalidKey(combo) }
            try ax.sendKey(parsed)
        case .shell(let command, let waitForExit, let timeout):
            let result = try await process.runShell(command, waitForExit: waitForExit, timeout: timeout)
            if waitForExit, result.exitCode != 0 { throw ActionError.shellFailed(result.exitCode, result.output) }
        case .openURL(let url):
            try await process.openURL(url)
        case .runShortcut(let name):
            let result = try await process.runShortcut(name, timeout: step.timeout)
            if result.exitCode != 0 { throw ActionError.shellFailed(result.exitCode, result.output) }
        case .waitFor(let locator, let containing, let timeout):
            _ = try await locate(locator, containing: containing, timeout: timeout)
        case .delay(let seconds):
            try await clock.sleep(seconds)
        case .optional(let inner):
            try await execute(inner)
        }
    }

    /// Polls every 200 ms until the element (and optional text) is there or `timeout` has passed.
    func locate(_ locator: ElementLocator, containing text: String?, timeout: TimeInterval) async throws -> any AXNode {
        let deadline = clock.now() + timeout
        var sawElement = false
        while true {
            try Task.checkCancellation()
            if let node = ElementSearch.find(locator, roots: ax.roots(bundleID: locator.bundleID)) {
                sawElement = true
                guard let text, !text.isEmpty else { return node }
                if (node.value ?? "").localizedCaseInsensitiveContains(text)
                    || (node.title ?? "").localizedCaseInsensitiveContains(text) { return node }
            }
            if clock.now() >= deadline { break }
            try await clock.sleep(min(ActionDefaults.pollInterval, max(0.001, deadline - clock.now())))
        }
        throw sawElement ? ActionError.valueMismatch(locator.describe) : ActionError.elementNotFound(locator.describe)
    }

    func pressMenu(bundleID: String, path: [String], timeout: TimeInterval) async throws {
        let deadline = clock.now() + timeout
        while true {
            try Task.checkCancellation()
            if let bar = ax.menuBar(bundleID: bundleID), let item = ElementSearch.menuItem(path: path, in: bar) {
                if item.press() { return }
                throw ActionError.pressFailed(path.joined(separator: " > "))
            }
            if clock.now() >= deadline { break }
            try await clock.sleep(ActionDefaults.pollInterval)
        }
        throw ActionError.menuItemNotFound(path.joined(separator: " > "))
    }
}
