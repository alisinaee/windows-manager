import AppKit
import ApplicationServices
import Foundation

// Probes for "Virtual desktops" mode, part 1: hiding and unhiding whole apps.
// The app keeps its own workspaces; one way to switch workspace is to hide the apps of the old one
// (NSRunningApplication.hide) and unhide the apps of the new one. These helpers measure how fast and how
// cleanly macOS does that. They are lab probes, not the final engine.

// MARK: - Stage Manager

/// Whether Stage Manager is on. It changes how windows hide and park (windows can sit in the side strip),
/// so every virtual-mode lab result records it.
public struct StageManagerState: Codable, Equatable {
    /// `GloballyEnabled` in com.apple.WindowManager; nil when the key is not set (macOS then treats it as off).
    public var enabled: Bool?
    /// Other com.apple.WindowManager keys that were present, as text.
    public var settings: [String: String]

    public init(enabled: Bool?, settings: [String: String] = [:]) {
        self.enabled = enabled
        self.settings = settings
    }

    public var isOn: Bool { enabled ?? false }

    /// "ON", "off" or "off (key not set)".
    public var summary: String {
        switch enabled {
        case .some(true): return "ON"
        case .some(false): return "off"
        case .none: return "off (key not set)"
        }
    }

    /// Keys of com.apple.WindowManager that are read besides `GloballyEnabled`.
    public static let extraKeys = [
        "AutoHide", "AppWindowGroupingBehavior", "HideDesktop", "StandardHideDesktopIcons",
        "StandardHideWidgets", "StageManagerHideWidgets",
    ]

    /// Reads com.apple.WindowManager through CFPreferences. Read-only.
    public static func read() -> StageManagerState {
        let domain = "com.apple.WindowManager" as CFString
        var raw: [String: Any] = [:]
        for key in ["GloballyEnabled"] + extraKeys {
            if let value = CFPreferencesCopyAppValue(key as CFString, domain) { raw[key] = value }
        }
        return parse(raw)
    }

    /// Pure: builds the state from already-read preference values.
    public static func parse(_ raw: [String: Any]) -> StageManagerState {
        var enabled: Bool?
        if let value = raw["GloballyEnabled"] {
            enabled = (value as? NSNumber)?.boolValue
        }
        var settings: [String: String] = [:]
        for key in extraKeys {
            if let value = raw[key] { settings[key] = "\(value)" }
        }
        return StageManagerState(enabled: enabled, settings: settings)
    }
}

// MARK: - Cheap window list

/// One normal window (layer 0) as the window server lists it.
public struct WindowListEntry: Codable, Equatable {
    public var windowID: UInt32
    public var pid: Int32
    /// Global screen coordinates (origin top-left of the main display, y grows downward).
    public var bounds: CGRect
    public var alpha: Double
    public var isOnScreen: Bool

    public init(windowID: UInt32, pid: Int32, bounds: CGRect, alpha: Double, isOnScreen: Bool) {
        self.windowID = windowID
        self.pid = pid
        self.bounds = bounds
        self.alpha = alpha
        self.isOnScreen = isOnScreen
    }
}

/// A light CGWindowList reader that is cheap enough to poll every few milliseconds
/// (unlike `WindowCatalog.all()`, it does no per-window Space or Accessibility work).
public enum WindowListReader {
    /// Layer-0 windows, optionally only the ones currently on screen and/or of one process.
    public static func windows(pid: Int32? = nil, onScreenOnly: Bool = false) -> [WindowListEntry] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var result: [WindowListEntry] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            if let pid, owner != pid { continue }
            var bounds = CGRect.zero
            if let dict = info[kCGWindowBounds as String] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) ?? .zero
            }
            result.append(WindowListEntry(
                windowID: wid, pid: owner, bounds: bounds,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false))
        }
        return result
    }

    /// One window by id (any state), or nil when the window server does not list it.
    public static func window(id: UInt32) -> WindowListEntry? {
        windows().first { $0.windowID == id }
    }

    /// Windows of `pid` that a person would see: on screen, not transparent, at least `minSide` points on
    /// the short side.
    public static func visibleWindows(pid: Int32, minSide: CGFloat = 50) -> [WindowListEntry] {
        windows(pid: pid, onScreenOnly: true).filter {
            $0.alpha > 0.01 && min($0.bounds.width, $0.bounds.height) >= minSide
        }
    }
}

// MARK: - App hiding

/// One window whose frame was different after an unhide.
public struct FrameDifference: Codable, Equatable {
    public var windowID: UInt32
    /// "cg" (CGWindowList bounds) or "ax" (Accessibility frame).
    public var source: String
    public var before: CGRect
    /// nil when the window could not be found afterwards.
    public var after: CGRect?

    public init(windowID: UInt32, source: String, before: CGRect, after: CGRect?) {
        self.windowID = windowID
        self.source = source
        self.before = before
        self.after = after
    }
}

public enum AppHider {
    public struct Options {
        /// How long to wait for each signal before giving up.
        public var timeout: TimeInterval
        public var pollInterval: TimeInterval
        /// Pause between the hide and the unhide, and after the unhide before frames are compared.
        public var dwell: TimeInterval
        public var settle: TimeInterval

        public init(timeout: TimeInterval = 3, pollInterval: TimeInterval = 0.02,
                    dwell: TimeInterval = 0.4, settle: TimeInterval = 0.3) {
            self.timeout = timeout
            self.pollInterval = pollInterval
            self.dwell = dwell
            self.settle = settle
        }
    }

    /// One hide + unhide round trip. Times are seconds since the hide() / unhide() call; nil = never seen
    /// within the timeout.
    public struct Cycle: Codable, Equatable {
        public var windowsBefore = 0
        public var hideAccepted = false
        public var hideCallSeconds: TimeInterval = 0
        /// NSRunningApplication.isHidden became true.
        public var hiddenFlagAfter: TimeInterval?
        /// The Accessibility AXHidden attribute of the app became true (nil too when AX is not trusted).
        public var axHiddenAfter: TimeInterval?
        public var firstWindowGoneAfter: TimeInterval?
        public var allWindowsGoneAfter: TimeInterval?
        /// Tracked windows that were still in the on-screen list when the wait ended.
        public var windowsStillOnScreen: [UInt32] = []
        public var frontmostAfterHide: String?

        public var unhideAccepted = false
        public var unhideCallSeconds: TimeInterval = 0
        public var shownFlagAfter: TimeInterval?
        public var axShownAfter: TimeInterval?
        public var firstWindowBackAfter: TimeInterval?
        public var allWindowsBackAfter: TimeInterval?
        public var windowsMissingAfterUnhide: [UInt32] = []
        public var frontmostAfterUnhide: String?

        /// Windows whose CG or AX frame changed between before the hide and after the unhide.
        public var frameDifferences: [FrameDifference] = []

        public init() {}

        /// Everything worked: both calls accepted, the hidden flag followed, tracked windows left and came
        /// back, and no frame changed.
        public var succeeded: Bool {
            let windowsOK = windowsBefore == 0 || (allWindowsGoneAfter != nil && allWindowsBackAfter != nil)
            return hideAccepted && unhideAccepted && hiddenFlagAfter != nil && shownFlagAfter != nil
                && windowsOK && frameDifferences.isEmpty
        }
    }

    public struct Report: Codable, Equatable {
        public var appName = ""
        public var bundleID: String?
        public var pid: Int32 = 0
        public var activationPolicy = ""
        public var axTrusted = false
        public var cycles: [Cycle] = []
        public var frontmostBefore: String?
        /// True when the app that was frontmost before the test is frontmost again at the end.
        public var frontmostRestored: Bool?
        /// The app was still hidden at the end and had to be unhidden by the safety net.
        public var neededSafetyUnhide = false
        public var interrupted = false

        public init() {}
    }

    // MARK: Reading state

    /// NSRunningApplication.isHidden of a fresh lookup (an old instance may hold a cached value).
    public static func isHidden(pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
    }

    /// AXHidden of the application element; nil when AX is not trusted or the attribute cannot be read.
    public static func axHidden(pid: Int32) -> Bool? {
        guard AXPermission.isTrusted() else { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1.0)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXHiddenAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    /// Accessibility frames of the given windows of an app, keyed by window id. Empty without AX permission.
    public static func axFrames(of app: NSRunningApplication, windowIDs: Set<UInt32>) -> [UInt32: CGRect] {
        guard AXPermission.isTrusted() else { return [:] }
        var frames: [UInt32: CGRect] = [:]
        for element in AXWindows.windows(of: app) {
            guard let wid = AXWindows.windowID(of: element), windowIDs.contains(wid),
                  let frame = AXWindows.frame(of: element) else { continue }
            frames[wid] = frame
        }
        return frames
    }

    static func frontmostName() -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.localizedName ?? app?.bundleIdentifier
    }

    // MARK: Pure comparison

    /// Windows of `before` that moved or resized by more than `tolerance` points in `after`, or that are
    /// missing from `after`. Pure.
    public static func frameDifferences(before: [UInt32: CGRect], after: [UInt32: CGRect], source: String,
                                        tolerance: CGFloat = 1) -> [FrameDifference] {
        var result: [FrameDifference] = []
        for wid in before.keys.sorted() {
            guard let was = before[wid] else { continue }
            guard let now = after[wid] else {
                result.append(FrameDifference(windowID: wid, source: source, before: was, after: nil))
                continue
            }
            if abs(was.minX - now.minX) > tolerance || abs(was.minY - now.minY) > tolerance
                || abs(was.width - now.width) > tolerance || abs(was.height - now.height) > tolerance {
                result.append(FrameDifference(windowID: wid, source: source, before: was, after: now))
            }
        }
        return result
    }

    // MARK: Experiment

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Why an app cannot be used for the hide test, or nil when it can.
    public static func problem(with app: NSRunningApplication) -> String? {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return "that is this tool itself"
        }
        if app.activationPolicy != .regular {
            return "\(app.localizedName ?? "the app") is not a regular app (hide() only works on apps with a Dock icon)"
        }
        return nil
    }

    /// Hides and unhides `app` `repeatCount` times and measures each step.
    /// Whatever happens (even an abort between steps), the app is unhidden and the previously frontmost app
    /// is activated again before this returns. Nothing here throws, so the cleanup at the end always runs.
    public static func test(app: NSRunningApplication, repeatCount: Int, options: Options = Options(),
                            shouldAbort: () -> Bool = { false }, log: (String) -> Void = { _ in }) -> Report {
        let pid = app.processIdentifier
        var report = Report()
        report.appName = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
        report.bundleID = app.bundleIdentifier
        report.pid = pid
        report.axTrusted = AXPermission.isTrusted()
        switch app.activationPolicy {
        case .regular: report.activationPolicy = "regular"
        case .accessory: report.activationPolicy = "accessory"
        case .prohibited: report.activationPolicy = "prohibited"
        @unknown default: report.activationPolicy = "unknown"
        }
        let previouslyFrontmost = NSWorkspace.shared.frontmostApplication
        report.frontmostBefore = previouslyFrontmost?.localizedName ?? previouslyFrontmost?.bundleIdentifier

        if isHidden(pid: pid) {
            log("app is already hidden before the test; unhiding it first")
            app.unhide()
            _ = waitUntil(timeout: options.timeout, interval: options.pollInterval) { !isHidden(pid: pid) }
        }

        for n in 1...max(1, repeatCount) {
            if shouldAbort() { report.interrupted = true; break }
            log("cycle \(n)/\(max(1, repeatCount))")
            report.cycles.append(runCycle(app: app, options: options, shouldAbort: shouldAbort, log: log))
            if shouldAbort() { report.interrupted = true; break }
            // Small gap between cycles so the app is back at rest.
            _ = waitUntil(timeout: options.settle, interval: options.pollInterval) { shouldAbort() }
        }

        // Safety net, always run: never leave the app hidden, and give focus back.
        if isHidden(pid: pid) {
            report.neededSafetyUnhide = true
            log("safety: app still hidden, unhiding")
            NSRunningApplication(processIdentifier: pid)?.unhide()
            _ = waitUntil(timeout: options.timeout, interval: options.pollInterval) { !isHidden(pid: pid) }
        }
        if let previouslyFrontmost, previouslyFrontmost.processIdentifier != pid,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != previouslyFrontmost.processIdentifier {
            previouslyFrontmost.activate()
            _ = waitUntil(timeout: 1.0, interval: options.pollInterval) {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == previouslyFrontmost.processIdentifier
            }
        }
        report.frontmostRestored = previouslyFrontmost.map {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == $0.processIdentifier
        }
        return report
    }

    /// One hide + unhide with timing. Does not restore anything by itself; `test` does.
    static func runCycle(app: NSRunningApplication, options: Options, shouldAbort: () -> Bool,
                         log: (String) -> Void) -> Cycle {
        let pid = app.processIdentifier
        var cycle = Cycle()

        // Before: the windows a person sees, with their frames from CG and from AX.
        let tracked = WindowListReader.visibleWindows(pid: pid)
        let trackedIDs = Set(tracked.map(\.windowID))
        let cgBefore = Dictionary(tracked.map { ($0.windowID, $0.bounds) }, uniquingKeysWith: { first, _ in first })
        let axBefore = axFrames(of: app, windowIDs: trackedIDs)
        // AX is only used as a signal when it is trusted and the app answers for AXHidden at all.
        let axAvailable = axHidden(pid: pid) != nil
        cycle.windowsBefore = tracked.count
        log("before: \(tracked.count) visible window(s), \(axBefore.count) with an AX frame")

        // Hide.
        let hideStart = uptime()
        cycle.hideAccepted = app.hide()
        cycle.hideCallSeconds = uptime() - hideStart
        log("hide() returned \(cycle.hideAccepted) after \(ms(cycle.hideCallSeconds))")
        _ = waitUntil(timeout: options.timeout, interval: options.pollInterval) {
            let t = uptime() - hideStart
            if cycle.hiddenFlagAfter == nil, isHidden(pid: pid) { cycle.hiddenFlagAfter = t }
            if axAvailable, cycle.axHiddenAfter == nil, axHidden(pid: pid) == true { cycle.axHiddenAfter = t }
            let onScreen = Set(WindowListReader.windows(pid: pid, onScreenOnly: true).map(\.windowID))
            let remaining = trackedIDs.intersection(onScreen)
            if cycle.firstWindowGoneAfter == nil, remaining.count < trackedIDs.count { cycle.firstWindowGoneAfter = t }
            if cycle.allWindowsGoneAfter == nil, remaining.isEmpty, !trackedIDs.isEmpty { cycle.allWindowsGoneAfter = t }
            if shouldAbort() { return true }
            return cycle.hiddenFlagAfter != nil
                && (trackedIDs.isEmpty || cycle.allWindowsGoneAfter != nil)
                && (!axAvailable || cycle.axHiddenAfter != nil)
        }
        let stillOn = Set(WindowListReader.windows(pid: pid, onScreenOnly: true).map(\.windowID))
        cycle.windowsStillOnScreen = trackedIDs.intersection(stillOn).sorted()
        cycle.frontmostAfterHide = frontmostName()
        log("hidden flag \(timeText(cycle.hiddenFlagAfter)), AX hidden \(timeText(cycle.axHiddenAfter)), "
            + "windows gone \(timeText(cycle.allWindowsGoneAfter)); frontmost now \(cycle.frontmostAfterHide ?? "?")")

        // Hold the hidden state a moment so it is a real hide, not a flicker.
        _ = waitUntil(timeout: options.dwell, interval: options.pollInterval) { shouldAbort() }

        // Unhide.
        let showStart = uptime()
        cycle.unhideAccepted = app.unhide()
        cycle.unhideCallSeconds = uptime() - showStart
        log("unhide() returned \(cycle.unhideAccepted) after \(ms(cycle.unhideCallSeconds))")
        _ = waitUntil(timeout: options.timeout, interval: options.pollInterval) {
            let t = uptime() - showStart
            if cycle.shownFlagAfter == nil, !isHidden(pid: pid) { cycle.shownFlagAfter = t }
            if axAvailable, cycle.axShownAfter == nil, axHidden(pid: pid) == false { cycle.axShownAfter = t }
            let onScreen = Set(WindowListReader.windows(pid: pid, onScreenOnly: true).map(\.windowID))
            let back = trackedIDs.intersection(onScreen)
            if cycle.firstWindowBackAfter == nil, !back.isEmpty { cycle.firstWindowBackAfter = t }
            if cycle.allWindowsBackAfter == nil, back.count == trackedIDs.count, !trackedIDs.isEmpty {
                cycle.allWindowsBackAfter = t
            }
            if shouldAbort() { return true }
            return cycle.shownFlagAfter != nil
                && (trackedIDs.isEmpty || cycle.allWindowsBackAfter != nil)
                && (!axAvailable || cycle.axShownAfter != nil)
        }
        let backNow = Set(WindowListReader.windows(pid: pid, onScreenOnly: true).map(\.windowID))
        cycle.windowsMissingAfterUnhide = trackedIDs.subtracting(backNow).sorted()
        cycle.frontmostAfterUnhide = frontmostName()
        log("shown flag \(timeText(cycle.shownFlagAfter)), AX shown \(timeText(cycle.axShownAfter)), "
            + "windows back \(timeText(cycle.allWindowsBackAfter)); frontmost now \(cycle.frontmostAfterUnhide ?? "?")")

        // Frames after the app has settled.
        _ = waitUntil(timeout: options.settle, interval: options.pollInterval) { shouldAbort() }
        let cgAfterList = WindowListReader.windows(pid: pid)
        let cgAfter = Dictionary(cgAfterList.filter { trackedIDs.contains($0.windowID) }.map { ($0.windowID, $0.bounds) },
                                 uniquingKeysWith: { first, _ in first })
        cycle.frameDifferences = frameDifferences(before: cgBefore, after: cgAfter, source: "cg")
            + frameDifferences(before: axBefore, after: axFrames(of: app, windowIDs: trackedIDs), source: "ax")
        log(cycle.frameDifferences.isEmpty
            ? "frames unchanged after unhide"
            : "\(cycle.frameDifferences.count) frame difference(s) after unhide")
        return cycle
    }

    // MARK: Text helpers

    static func ms(_ seconds: TimeInterval) -> String { String(format: "%.0f ms", seconds * 1000) }

    static func timeText(_ seconds: TimeInterval?) -> String {
        seconds.map { ms($0) } ?? "never"
    }
}
