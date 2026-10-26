import Foundation

// The launch order of a profile (Profile Studio, "Launch order"). A profile without a `LaunchPlan` keeps the
// old behavior: every closed app launches in parallel. Files written before this type existed decode with
// `launchPlan == nil`, and a nil plan is never written, so old profiles re-encode byte-identical.

/// The order and timing of launching the apps of a profile.
public struct LaunchPlan: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable {
        /// One app after another, each with its own wait and delay.
        case sequential
        /// Every app at once, as profiles did before the launch order existed.
        case parallel
    }

    public var mode: Mode
    /// Explicit order. Apps not listed here launch after these, in profile order.
    public var items: [LaunchItem]

    public init(mode: Mode = .sequential, items: [LaunchItem] = []) {
        self.mode = mode
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case mode, items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .sequential
        items = try c.decodeIfPresent([LaunchItem].self, forKey: .items) ?? []
    }
}

/// When a launch step counts as finished.
public enum LaunchWait: String, Codable, Hashable, Sendable {
    /// Wait until the app has the windows the profile plans for it (or the timeout passes).
    case windows
    /// Wait only until the app is running and ready, without looking at its windows.
    case appReady
}

/// One app in the launch order.
public struct LaunchItem: Codable, Hashable, Sendable, Identifiable {
    public static let defaultEnabled = true
    public static let defaultWait = LaunchWait.windows
    /// Seconds to wait after this app before the next one (sequential mode only).
    public static let delayRange: ClosedRange<TimeInterval> = 0...60
    /// Seconds to wait for the app (or its windows); nil means the engine's default timeout.
    public static let timeoutRange: ClosedRange<TimeInterval> = 5...120

    public var app: AppRef
    /// false = never launch this app. Its windows are still placed if it is already running.
    public var enabled: Bool
    public var wait: LaunchWait
    /// Clamped to `delayRange` whenever it is set, decoded or created.
    public var delayAfter: TimeInterval {
        didSet { delayAfter = Self.clampDelay(delayAfter) }
    }
    /// Clamped to `timeoutRange` when set; nil keeps the engine's default timeout.
    public var timeout: TimeInterval? {
        didSet { timeout = Self.clampTimeout(timeout) }
    }
    /// Bring the app to the front after it launches.
    public var activates: Bool
    /// true = launch only. The app is expected to have no windows, so nothing waits for one.
    public var withoutWindows: Bool

    public init(app: AppRef, enabled: Bool = defaultEnabled, wait: LaunchWait = defaultWait,
                delayAfter: TimeInterval = 0, timeout: TimeInterval? = nil, activates: Bool = false,
                withoutWindows: Bool = false) {
        self.app = app
        self.enabled = enabled
        self.wait = wait
        self.delayAfter = Self.clampDelay(delayAfter)
        self.timeout = Self.clampTimeout(timeout)
        self.activates = activates
        self.withoutWindows = withoutWindows
    }

    /// Identity of the item: the lower-cased bundle id, otherwise "name:" plus the lower-cased name.
    /// Computed from `app`, so it is never stored and never out of step with it.
    public var id: String {
        if let bundleID = app.bundleID, !bundleID.isEmpty { return bundleID.lowercased() }
        return "name:" + app.name.lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case app, enabled, wait, delayAfter, timeout, activates, withoutWindows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(AppRef.self, forKey: .app)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.defaultEnabled

        let waitText = try c.decodeIfPresent(String.self, forKey: .wait) ?? Self.defaultWait.rawValue
        guard let parsedWait = LaunchWait(rawValue: waitText) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath + [CodingKeys.wait],
                debugDescription: "Unknown launch wait \"\(waitText)\" for \(app.name). "
                    + "Use \"windows\" (wait for the app's windows) or \"appReady\" (wait only until the app is ready)."))
        }
        wait = parsedWait

        delayAfter = Self.clampDelay(try c.decodeIfPresent(TimeInterval.self, forKey: .delayAfter) ?? 0)
        timeout = Self.clampTimeout(try c.decodeIfPresent(TimeInterval.self, forKey: .timeout))
        activates = try c.decodeIfPresent(Bool.self, forKey: .activates) ?? false
        withoutWindows = try c.decodeIfPresent(Bool.self, forKey: .withoutWindows) ?? false
    }

    /// Keeps a delay in `delayRange`. A value that is not a number becomes 0.
    static func clampDelay(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 0 }
        return min(max(seconds, delayRange.lowerBound), delayRange.upperBound)
    }

    /// Keeps a timeout in `timeoutRange`. A value that is not a number becomes nil (the default timeout).
    static func clampTimeout(_ seconds: TimeInterval?) -> TimeInterval? {
        guard let seconds, seconds.isFinite else { return nil }
        return min(max(seconds, timeoutRange.lowerBound), timeoutRange.upperBound)
    }
}
