import CoreGraphics
import Foundation

/// One element of an accessibility tree. Real implementation wraps AXElement; tests use a fake tree.
public protocol AXNode: AnyObject, Sendable {
    var role: String? { get }
    var subrole: String? { get }
    var title: String? { get }
    var identifier: String? { get }
    var descriptionText: String? { get }
    var value: String? { get }
    func children() -> [any AXNode]
    /// AXPress. Returns false if the element refused.
    func press() -> Bool
    /// Gives the element keyboard focus (AXFocused, falling back to a press).
    func focus() -> Bool
    /// Runs an accessibility action by name (AXConfirm, AXPick ...) when the element supports it.
    func performAction(_ name: String) -> Bool
    /// Sets AXFocused when that attribute is settable.
    func setFocusedIfSettable() -> Bool
    /// Center of the element's frame in global screen coordinates.
    var frameCenter: CGPoint? { get }
}

public extension AXNode {
    func performAction(_ name: String) -> Bool { false }
    func setFocusedIfSettable() -> Bool { false }
    var frameCenter: CGPoint? { nil }
}

public protocol AXProvider: Sendable {
    /// Top level nodes of the app to search: its windows (or the application element when it has none).
    /// Empty when the app is not running or AX is not available.
    func roots(bundleID: String) -> [any AXNode]
    /// The app's menu bar node, or nil.
    func menuBar(bundleID: String) -> (any AXNode)?
    func sendKey(_ combo: KeyCombo) throws
    func typeText(_ text: String) throws
    /// Brings the app to the front.
    func activate(bundleID: String)
    /// Posts a left click (mouse down and up) at a global screen point.
    func click(at point: CGPoint) throws
}

public extension AXProvider {
    func activate(bundleID: String) {}
    func click(at point: CGPoint) throws { throw ActionError.failed("clicking is not available") }
}

/// Runs AppleScript source. The real one uses NSAppleScript; tests use a fake.
public protocol ScriptRunner: Sendable {
    /// Throws `ScriptError` when the script fails.
    func run(_ source: String) async throws
}

public struct ScriptError: Error, Equatable, Sendable {
    public var number: Int
    public var message: String
    public init(number: Int, message: String) { self.number = number; self.message = message }
    /// errAEEventNotPermitted: the user has not allowed this app to control the other one.
    public static let automationDenied = -1743
}

public struct ShellResult: Equatable, Sendable {
    public var exitCode: Int32
    public var output: String
    public init(exitCode: Int32, output: String = "") { self.exitCode = exitCode; self.output = output }
}

public protocol ProcessRunner: Sendable {
    /// Runs `command` with /bin/zsh -lc. With waitForExit false returns right after the launch (exit code 0).
    /// Throws `ActionError.timedOut` when it runs longer than `timeout`.
    func runShell(_ command: String, waitForExit: Bool, timeout: TimeInterval) async throws -> ShellResult
    /// `/usr/bin/shortcuts run <name>`
    func runShortcut(_ name: String, timeout: TimeInterval) async throws -> ShellResult
    func launchApp(bundleID: String, timeout: TimeInterval) async throws
    func openURL(_ url: String) async throws
}

public protocol ActionClock: Sendable {
    /// Monotonic seconds.
    func now() -> TimeInterval
    /// Throws CancellationError when the task is cancelled.
    func sleep(_ seconds: TimeInterval) async throws
}

public struct SystemClock: ActionClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

public enum ActionError: Error, Equatable, LocalizedError, Sendable {
    case notTrusted
    case elementNotFound(String)
    case valueMismatch(String)
    case pressFailed(String)
    case menuItemNotFound(String)
    case invalidKey(String)
    case shellFailed(Int32, String)
    case timedOut(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notTrusted: return "Accessibility permission is missing"
        case .elementNotFound(let s): return "element not found: \(s)"
        case .valueMismatch(let s): return "element found but its text does not match: \(s)"
        case .pressFailed(let s): return "could not press \(s)"
        case .menuItemNotFound(let s): return "menu item not found: \(s)"
        case .invalidKey(let s): return "invalid key combination: \(s)"
        case .shellFailed(let code, let out): return "command exited with \(code)" + (out.isEmpty ? "" : ": \(out)")
        case .timedOut(let s): return "timed out: \(s)"
        case .failed(let s): return s
        }
    }
}
