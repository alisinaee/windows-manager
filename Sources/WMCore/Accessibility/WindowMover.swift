import AppKit
import ApplicationServices
import Foundation

// Production way to place a window through the Accessibility API.
//
// The recipe follows ideas from Rectangle (https://github.com/rxhanson/Rectangle, MIT license; see
// AccessibilityElement.swift and the WindowMover folder there): write the size first, then the position,
// then the size again; skip writes that would change nothing; switch the app's AXEnhancedUserInterface off
// while writing (it makes windows animate and lag) and switch it back on afterwards, except for
// Chromium-based apps; treat a result more than 1 point off as "minimum size reached or refused"; and
// retry once, because a refused size can succeed after the window has been moved on-screen.
// No Rectangle code is copied; this is our own implementation of the same ideas.

// MARK: - Types

/// One AX write that `WindowMover` can make while placing a window.
public enum FrameWrite: String, Codable, Equatable, Sendable {
    case size
    case position
}

/// One write that was actually sent to the app.
public struct FrameMoveStep: Equatable, Sendable {
    public var write: FrameWrite
    /// `AXError.rawValue` of the call; 0 means success.
    public var errorCode: Int32
    /// True for writes made by the retry pass.
    public var isRetry: Bool

    public init(write: FrameWrite, errorCode: Int32 = 0, isRetry: Bool = false) {
        self.write = write
        self.errorCode = errorCode
        self.isRetry = isRetry
    }

    public var succeeded: Bool { errorCode == AXError.success.rawValue }
}

public struct FrameMoveOptions: Equatable, Sendable {
    /// A frame counts as reached when every value is at most this many points away (Rectangle uses 1).
    public var tolerance: CGFloat = 1
    /// Extra passes after the first one when the result is off (1 = retry once).
    public var retries: Int = 1
    /// Turn the app's AXEnhancedUserInterface off while writing and restore it afterwards
    /// (not restored for Chromium-based apps).
    public var disableEnhancedUserInterface: Bool = true
    /// After writing, wait up to this long (seconds) for the frame to stop changing before judging it.
    public var settleTimeout: TimeInterval = 0.1
    public var settleInterval: TimeInterval = 0.02
    /// Stop starting new AX calls after this many seconds, so a hung app cannot hold the caller.
    public var maxDuration: TimeInterval = 3

    public static let `default` = FrameMoveOptions()

    public init() {}
}

/// What happened when a window was placed.
public struct FrameMoveResult: Equatable, Sendable {
    public var requested: CGRect
    /// Frame before the first write; nil when it could not be read.
    public var initial: CGRect?
    /// Frame read back after the last write; nil when it could not be read.
    public var actual: CGRect?
    /// Every write that was sent, in order. Empty when the window was already at the requested frame.
    public var steps: [FrameMoveStep]
    /// The window ended up larger than requested by more than the tolerance: it has a minimum size.
    public var minSizeHit: Bool
    /// The window is somewhere else than asked for and a minimum size does not explain it (position off,
    /// smaller than requested, an AX write was rejected, window gone).
    public var refused: Bool
    public var elapsed: TimeInterval
    /// AXEnhancedUserInterface was on and has been switched off for the writes.
    public var enhancedUIDisabled: Bool
    /// ... and has been switched back on (never for Chromium-based apps).
    public var enhancedUIRestored: Bool

    public init(requested: CGRect, initial: CGRect? = nil, actual: CGRect? = nil, steps: [FrameMoveStep] = [],
                minSizeHit: Bool = false, refused: Bool = false, elapsed: TimeInterval = 0,
                enhancedUIDisabled: Bool = false, enhancedUIRestored: Bool = false) {
        self.requested = requested
        self.initial = initial
        self.actual = actual
        self.steps = steps
        self.minSizeHit = minSizeHit
        self.refused = refused
        self.elapsed = elapsed
        self.enhancedUIDisabled = enhancedUIDisabled
        self.enhancedUIRestored = enhancedUIRestored
    }

    /// The window is at the requested frame (within the tolerance used for the move, 1 point by default).
    public var matched: Bool { !minSizeHit && !refused }
    public var retried: Bool { steps.contains { $0.isRetry } }
}

// MARK: - WindowMover

public enum WindowMover {
    // MARK: Placing a window

    /// Places `window` at `frame` (global top-left coordinates) and reads the result back.
    ///
    /// Safe to call for any window; it never throws and never blocks longer than `options.maxDuration`
    /// plus one AX timeout. Full-screen and minimized windows ignore the writes and come back `refused`.
    public static func setFrame(_ window: AXElement, to frame: CGRect,
                                options: FrameMoveOptions = .default) -> FrameMoveResult {
        let started = uptime()
        var enhancedUI: EnhancedUIGuard?
        var result = apply(AXFrameAccess(window: window), requested: frame, options: options, beforeFirstWrite: {
            if options.disableEnhancedUserInterface { enhancedUI = EnhancedUIGuard.disable(for: window) }
        })
        if let enhancedUI {
            result.enhancedUIDisabled = true
            result.enhancedUIRestored = enhancedUI.restore()
        }
        result.elapsed = uptime() - started
        return result
    }

    // MARK: Pure planning and judging

    /// Which writes are needed to turn `current` into `target`. Writes that would change nothing are left
    /// out. Moving and resizing together uses size, position, size: the first size lets the window fit the
    /// target screen, the last one fixes a size that was clamped while it still sat on the old screen.
    public static func plan(current: CGRect, target: CGRect, tolerance: CGFloat = 1) -> [FrameWrite] {
        let sizeOff = !sizeMatches(current.size, target.size, tolerance: tolerance)
        let positionOff = !positionMatches(current.origin, target.origin, tolerance: tolerance)
        switch (sizeOff, positionOff) {
        case (false, false): return []
        case (true, false): return [.size]
        case (false, true): return [.position]
        case (true, true): return [.size, .position, .size]
        }
    }

    /// Writes for the retry pass: move the window to its target first (so it is on-screen where it should
    /// be), then ask for the size again. Writes that would change nothing are left out.
    public static func retryPlan(current: CGRect, target: CGRect, tolerance: CGFloat = 1) -> [FrameWrite] {
        var writes: [FrameWrite] = []
        if !positionMatches(current.origin, target.origin, tolerance: tolerance) { writes.append(.position) }
        if !sizeMatches(current.size, target.size, tolerance: tolerance) { writes.append(.size) }
        return writes
    }

    /// True when every value differs by at most `tolerance` points.
    public static func frameMatches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        positionMatches(a.origin, b.origin, tolerance: tolerance) && sizeMatches(a.size, b.size, tolerance: tolerance)
    }

    public static func positionMatches(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 1) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    public static func sizeMatches(_ a: CGSize, _ b: CGSize, tolerance: CGFloat = 1) -> Bool {
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Judges a read-back. `minSizeHit`: larger than requested in at least one dimension (a minimum size
    /// keeps the window from shrinking). `refused`: anything else that is more than `tolerance` off, or no
    /// read-back at all. Both can be true at once, for example when a minimum size pushed the window up.
    public static func verdict(requested: CGRect, actual: CGRect?, tolerance: CGFloat = 1)
        -> (minSizeHit: Bool, refused: Bool) {
        guard let actual else { return (false, true) }
        let tooLarge = actual.width > requested.width + tolerance || actual.height > requested.height + tolerance
        let tooSmall = actual.width < requested.width - tolerance || actual.height < requested.height - tolerance
        let positionOff = !positionMatches(actual.origin, requested.origin, tolerance: tolerance)
        return (tooLarge, tooSmall || positionOff)
    }

    // MARK: Full screen, raise, minimize

    /// Turns AXFullScreen on or off and waits until it reads back as `on`. True when it did within
    /// `timeout` seconds. Returns at once when the window is already in that state. The wait keeps the
    /// current run loop spinning (see `waitUntil`).
    @discardableResult
    public static func setFullScreen(_ window: AXElement, _ on: Bool, timeout: TimeInterval = 3) -> Bool {
        let attribute = AXElement.fullScreenAttribute
        if window.bool(attribute) == on { return true }
        guard window.set(attribute, on).isSuccess else { return false }
        return waitUntil(timeout: timeout) { window.bool(attribute) == on } != nil
    }

    /// Brings the window to the front of its app (AXRaise). It does not activate the app.
    @discardableResult
    public static func raise(_ window: AXElement) -> Bool {
        window.perform(kAXRaiseAction).isSuccess
    }

    /// Minimizes the window and waits until AXMinimized reads back true.
    @discardableResult
    public static func minimize(_ window: AXElement, timeout: TimeInterval = 1) -> Bool {
        setMinimized(window, true, timeout: timeout)
    }

    /// Restores a minimized window and waits until AXMinimized reads back false.
    @discardableResult
    public static func unminimize(_ window: AXElement, timeout: TimeInterval = 1) -> Bool {
        setMinimized(window, false, timeout: timeout)
    }

    private static func setMinimized(_ window: AXElement, _ on: Bool, timeout: TimeInterval) -> Bool {
        if window.bool(kAXMinimizedAttribute) == on { return true }
        guard window.set(kAXMinimizedAttribute, on).isSuccess else { return false }
        return waitUntil(timeout: timeout) { window.bool(kAXMinimizedAttribute) == on } != nil
    }

    // MARK: Chromium detection

    /// Bundle ids of Chromium-based browsers. Matches the id itself and ids that continue it after a dot
    /// ("com.google.Chrome.canary").
    private static let chromiumBundleIDs = [
        "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaGX",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.github.Electron",
    ]

    /// Framework names (without ".framework", lower case) that Chromium, Chromium Embedded Framework and
    /// Electron apps carry in Contents/Frameworks.
    private static let chromiumFrameworkNames: Set<String> = [
        "electron framework", "chromium embedded framework", "chromium framework", "nwjs framework",
    ]

    /// Pure check. `frameworkNames` are the entries of the app's Contents/Frameworks folder, with or
    /// without the ".framework" suffix. Browser frameworks named "<Browser> Framework" with "chrom" in the
    /// name ("Google Chrome Framework") count as well.
    public static func isChromiumBased(bundleID: String?, frameworkNames: [String] = []) -> Bool {
        if let id = bundleID?.lowercased() {
            for known in chromiumBundleIDs {
                let known = known.lowercased()
                if id == known || id.hasPrefix(known + ".") { return true }
            }
        }
        for raw in frameworkNames {
            var name = raw.lowercased()
            if name.hasSuffix(".framework") { name.removeLast(".framework".count) }
            if chromiumFrameworkNames.contains(name) { return true }
            if name.hasSuffix(" framework") && name.contains("chrom") { return true }
            if name == "microsoft edge framework" || name == "brave browser framework"
                || name == "vivaldi framework" || name == "opera framework" { return true }
        }
        return false
    }

    /// Chromium check for a running app: its bundle id and the frameworks inside its bundle (cached per
    /// bundle path, because the folder listing is a disk read).
    public static func isChromiumBased(_ app: NSRunningApplication) -> Bool {
        let bundleID = app.bundleIdentifier
        if isChromiumBased(bundleID: bundleID) { return true }
        guard let bundleURL = app.bundleURL else { return false }
        let key = bundleURL.path
        if let cached = chromiumCache.value(for: key) { return cached }
        let frameworksPath = bundleURL.appendingPathComponent("Contents/Frameworks").path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworksPath)) ?? []
        let verdict = isChromiumBased(bundleID: bundleID, frameworkNames: names)
        chromiumCache.set(verdict, for: key)
        return verdict
    }

    private final class ChromiumCache: @unchecked Sendable {
        private let lock = NSLock()
        private var verdicts: [String: Bool] = [:]

        func value(for key: String) -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return verdicts[key]
        }

        func set(_ verdict: Bool, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            verdicts[key] = verdict
        }
    }

    private static let chromiumCache = ChromiumCache()

    // MARK: Engine (internal, tested with a fake window)

    /// The three things the placement loop needs from a window.
    protocol FrameAccess {
        func readFrame() -> CGRect?
        func writeSize(_ size: CGSize) -> AXError
        func writePosition(_ point: CGPoint) -> AXError
    }

    struct AXFrameAccess: FrameAccess {
        let window: AXElement
        func readFrame() -> CGRect? { window.frame }
        func writeSize(_ size: CGSize) -> AXError { window.set(kAXSizeAttribute, size) }
        func writePosition(_ point: CGPoint) -> AXError { window.set(kAXPositionAttribute, point) }
    }

    /// The placement loop: plan, write, wait for the frame to settle, judge, retry. `beforeFirstWrite` runs
    /// once, only when a write is really needed (used to switch AXEnhancedUserInterface off).
    static func apply(_ access: FrameAccess, requested: CGRect, options: FrameMoveOptions,
                      beforeFirstWrite: () -> Void = {},
                      sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> FrameMoveResult {
        let started = uptime()
        var result = FrameMoveResult(requested: requested)
        guard let initial = access.readFrame() else {
            result.refused = true
            result.elapsed = uptime() - started
            return result
        }
        result.initial = initial
        var current: CGRect? = initial
        var sizeWritable = true
        var positionWritable = true
        var gone = false
        var announced = false

        passLoop: for pass in 0...max(0, options.retries) {
            guard let frame = current else { break }
            let writes = pass == 0
                ? plan(current: frame, target: requested, tolerance: options.tolerance)
                : retryPlan(current: frame, target: requested, tolerance: options.tolerance)
            var wrote = false
            for write in writes {
                if gone || uptime() - started > options.maxDuration { gone = true; break }
                if write == .size && !sizeWritable { continue }
                if write == .position && !positionWritable { continue }
                if !announced { announced = true; beforeFirstWrite() }
                let error = write == .size ? access.writeSize(requested.size) : access.writePosition(requested.origin)
                result.steps.append(FrameMoveStep(write: write, errorCode: error.rawValue, isRetry: pass > 0))
                wrote = true
                if error != .success {
                    // A gone window ends everything; any other error only disables that kind of write
                    // (fixed-size windows reject size writes but still move).
                    switch error {
                    case .invalidUIElement: gone = true
                    default:
                        if write == .size { sizeWritable = false } else { positionWritable = false }
                    }
                }
            }
            if wrote { current = settle(access, requested: requested, options: options, sleep: sleep) }
            if gone || !wrote { break passLoop }
            if let current, frameMatches(current, requested, tolerance: options.tolerance) { break passLoop }
        }

        result.actual = current
        let judged = verdict(requested: requested, actual: current, tolerance: options.tolerance)
        let reached = current.map { frameMatches($0, requested, tolerance: options.tolerance) } ?? false
        let sizeRejected = result.steps.contains { $0.write == .size && !$0.succeeded }
        let anyRejected = result.steps.contains { !$0.succeeded }
        // A window whose size write was rejected (fixed size) stays large; that is a refusal, not a minimum.
        result.minSizeHit = judged.minSizeHit && !sizeRejected
        result.refused = judged.refused || (anyRejected && !reached)
        result.elapsed = uptime() - started
        return result
    }

    /// Reads the frame after writing. Polls until it matches `requested` or stops changing, at most
    /// `options.settleTimeout` seconds, because some apps apply a write a moment later.
    static func settle(_ access: FrameAccess, requested: CGRect, options: FrameMoveOptions,
                       sleep: (TimeInterval) -> Void) -> CGRect? {
        guard var previous = access.readFrame() else { return nil }
        var waited: TimeInterval = 0
        while !frameMatches(previous, requested, tolerance: options.tolerance), waited < options.settleTimeout {
            sleep(options.settleInterval)
            waited += options.settleInterval
            guard let next = access.readFrame() else { return nil }
            if next == previous { return next }
            previous = next
        }
        return previous
    }

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: AXEnhancedUserInterface

    /// Remembers that we switched AXEnhancedUserInterface off for an app.
    private struct EnhancedUIGuard {
        let app: AXElement
        let restoreAfterwards: Bool

        static func disable(for window: AXElement) -> EnhancedUIGuard? {
            guard let pid = window.pid else { return nil }
            let app = AXElement.application(pid: pid)
            guard app.bool(AXElement.enhancedUserInterfaceAttribute) == true,
                  app.set(AXElement.enhancedUserInterfaceAttribute, false).isSuccess else { return nil }
            let chromium = NSRunningApplication(processIdentifier: pid).map { WindowMover.isChromiumBased($0) } ?? false
            return EnhancedUIGuard(app: app, restoreAfterwards: !chromium)
        }

        /// True when the attribute was switched back on. Chromium-based apps are left as they are now:
        /// turning it on makes them build their full accessibility tree, which slows them down.
        func restore() -> Bool {
            guard restoreAfterwards else { return false }
            return app.set(AXElement.enhancedUserInterfaceAttribute, true).isSuccess
        }
    }
}
