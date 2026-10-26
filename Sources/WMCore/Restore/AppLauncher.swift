import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Opens apps that are not running yet and waits until they have usable windows (used by restore).
//
// What the wait has to cope with:
// - Electron apps (VS Code, Slack, Discord) and Telegram open a window and then resize or move it a moment
//   later, so "the window exists" is not enough: the frames must stop changing (see `isSettled`).
// - Apps with state restoration open several windows one after another (`minWindows`).
// - Some apps open no window at launch (menu bar apps, apps whose last window was closed). A reopen (the
//   same Apple event a Dock click sends) makes a normal app create one. It is sent at most twice and only
//   when neither AX nor the window server shows any window of the app.
// - Launching can take many seconds; every wait has a deadline.

// MARK: - Options and result

/// How `AppLauncher.launch` waits. The defaults match what restore needs; nothing here is applied to apps
/// that are already running.
public struct LaunchOptions: Equatable, Codable, Sendable {
    public static let defaultMinWindows = 1
    public static let defaultTimeout: TimeInterval = 20
    public static let defaultReopenAfter: TimeInterval = 3
    public static let defaultSettleTime: TimeInterval = 0.8
    public static let defaultMaxSettleTime: TimeInterval = 5

    /// Standard windows (AXWindow / AXStandardWindow with a real frame) to wait for. 0 waits only until the
    /// app answers Accessibility requests.
    public var minWindows: Int
    /// Seconds from the start of `launch` until the app must have `minWindows` windows.
    public var timeout: TimeInterval
    /// Seconds without any window (once the app is up and answers AX) before a reopen is sent.
    public var reopenAfter: TimeInterval
    /// Window frames must stay unchanged this long (seconds) before the app counts as settled.
    public var settleTime: TimeInterval
    /// Upper bound (seconds) for the settle wait. After it the result is reported with `timings.settled` nil.
    public var maxSettleTime: TimeInterval
    /// Bring the app to the front when opening it. False keeps the focus where it is.
    public var activates: Bool
    /// When the quiet reopen did not make a window appear, activate the app once as a last resort.
    /// This is the only case where an app takes the focus while `activates` is false.
    public var activateToReopen: Bool

    public init(minWindows: Int = LaunchOptions.defaultMinWindows,
                timeout: TimeInterval = LaunchOptions.defaultTimeout,
                reopenAfter: TimeInterval = LaunchOptions.defaultReopenAfter,
                settleTime: TimeInterval = LaunchOptions.defaultSettleTime,
                maxSettleTime: TimeInterval = LaunchOptions.defaultMaxSettleTime,
                activates: Bool = false,
                activateToReopen: Bool = true) {
        self.minWindows = minWindows
        self.timeout = timeout
        self.reopenAfter = reopenAfter
        self.settleTime = settleTime
        self.maxSettleTime = maxSettleTime
        self.activates = activates
        self.activateToReopen = activateToReopen
    }
}

/// What happened to one app. Times are seconds since `launch` was called.
public struct LaunchResult: Equatable, Codable, Sendable {
    public enum Status: Equatable, Codable, Sendable {
        /// The app was running before; nothing was opened and nothing was waited for.
        case alreadyRunning
        /// Opened by us and ready: `minWindows` windows exist (or, for apps without a Dock icon, the app
        /// answers AX and shows no window after the grace period; check `windowCount`).
        case launched
        /// No bundle id match, no saved path and no app with that name in the search folders.
        case notFound
        /// The app could not be opened (reason in the text), quit while starting, or the call was cancelled.
        case failed(String)
        /// The deadline passed before the app had `minWindows` windows. The app may still be running.
        case timedOut
    }

    public struct Timings: Equatable, Codable, Sendable {
        /// Duration of the `openApplication` call.
        public var launchCall: TimeInterval
        /// First time the app answered an AX windows request.
        public var axReady: TimeInterval?
        /// First time the app had a usable standard window.
        public var firstWindow: TimeInterval?
        /// Frames stayed unchanged for `settleTime`; nil when that never happened within `maxSettleTime`.
        public var settled: TimeInterval?
        /// Whole call.
        public var total: TimeInterval

        public init(launchCall: TimeInterval = 0, axReady: TimeInterval? = nil, firstWindow: TimeInterval? = nil,
                    settled: TimeInterval? = nil, total: TimeInterval = 0) {
            self.launchCall = launchCall
            self.axReady = axReady
            self.firstWindow = firstWindow
            self.settled = settled
            self.total = total
        }
    }

    public var app: AppRef
    public var status: Status
    public var pid: pid_t?
    /// Standard windows AX lists when the call ended. AX only lists windows of the Spaces that are visible.
    public var windowCount: Int
    /// Normal-level windows the window server knows for the app on any Space (nil when not measured).
    /// More than `windowCount` means some windows are on other Spaces (or not yet visible).
    public var systemWindowCount: Int?
    /// Reopen events sent because the app had no window.
    public var reopenCount: Int
    /// The last-resort reopen activated the app (it may have taken the focus).
    public var activatedToReopen: Bool
    public var timings: Timings

    public init(app: AppRef, status: Status, pid: pid_t? = nil, windowCount: Int = 0, systemWindowCount: Int? = nil,
                reopenCount: Int = 0, activatedToReopen: Bool = false, timings: Timings = Timings()) {
        self.app = app
        self.status = status
        self.pid = pid
        self.windowCount = windowCount
        self.systemWindowCount = systemWindowCount
        self.reopenCount = reopenCount
        self.activatedToReopen = activatedToReopen
        self.timings = timings
    }

    /// The app is running and can be worked with (`alreadyRunning` or `launched`).
    public var isRunning: Bool {
        switch status {
        case .alreadyRunning, .launched: return true
        case .notFound, .failed, .timedOut: return false
        }
    }

    /// The window frames were stable when the call ended.
    public var didSettle: Bool { timings.settled != nil }
}

// MARK: - AppLauncher

/// Finds, opens and waits for apps. Needs Accessibility permission to wait for windows; without it `launch`
/// reports `.failed` before opening anything. Safe to call from any thread; `launchAll` runs several launches
/// at once. Events from `AXObserverHub` wake the wait early, but polling every 100 ms is what the result
/// relies on, so the hub's main run loop does not have to be spinning.
public final class AppLauncher: @unchecked Sendable {
    /// Folders searched by name when neither the bundle id nor the saved path leads to the app.
    public static var defaultSearchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: NSString(string: "~/Applications").expandingTildeInPath, isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        ]
    }

    /// Delay between two looks at the app while waiting.
    public static let pollInterval: TimeInterval = 0.1

    /// Window frames at one moment, for `isSettled`.
    public struct FrameSample: Equatable, Sendable {
        /// Any monotonic clock in seconds (the launcher uses system uptime).
        public var time: TimeInterval
        public var frames: [CGRect]

        public init(time: TimeInterval, frames: [CGRect]) {
            self.time = time
            self.frames = frames
        }
    }

    public let searchDirectories: [URL]

    private let hub: AXObserverHub
    private let ownsHub: Bool
    private let fileManager: FileManager
    private let bundleLookup: @Sendable (String) -> URL?
    private let runningApplications: @Sendable () -> [NSRunningApplication]

    /// - Parameters:
    ///   - hub: The app's shared hub. Without one the launcher uses a private hub that watches only the apps it
    ///     launches, and stops watching them when the launch is over.
    ///   - fileManager, searchDirectories, bundleLookup, runningApplications: Injection points for tests.
    public init(hub: AXObserverHub? = nil,
                fileManager: FileManager = .default,
                searchDirectories: [URL]? = nil,
                bundleLookup: (@Sendable (String) -> URL?)? = nil,
                runningApplications: (@Sendable () -> [NSRunningApplication])? = nil) {
        if let hub {
            self.hub = hub
            ownsHub = false
        } else {
            var configuration = AXObserverHub.Configuration()
            configuration.notifications = [.windowCreated, .windowDestroyed, .windowMoved, .windowResized]
            self.hub = AXObserverHub(configuration: configuration)
            ownsHub = true
        }
        self.fileManager = fileManager
        self.searchDirectories = searchDirectories ?? Self.defaultSearchDirectories
        self.bundleLookup = bundleLookup ?? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        self.runningApplications = runningApplications ?? { NSWorkspace.shared.runningApplications }
    }

    // MARK: Finding the app

    /// Where the app lives now: the bundle id as Launch Services knows it, else the saved path if it still
    /// exists, else an app with the same name in `searchDirectories`. A name match is skipped when that app has
    /// a different bundle id than the one saved. Nil when nothing exists.
    public func resolveURL(for app: AppRef) -> URL? {
        if let id = app.bundleID, !id.isEmpty, let url = bundleLookup(id), isDirectory(url) {
            return url
        }
        if let path = app.path, !path.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
            if isDirectory(url) { return url }
        }
        return findByName(app.name, bundleID: app.bundleID)
    }

    /// The running process of the app: matched by bundle id when the profile has one, else by name.
    /// Prefers apps with a Dock icon when several processes match.
    public func isRunning(_ app: AppRef) -> NSRunningApplication? {
        let matches = runningApplications().filter { running in
            !running.isTerminated && Self.matches(app, bundleID: running.bundleIdentifier,
                                                  localizedName: running.localizedName,
                                                  bundleFileName: running.bundleURL?.lastPathComponent)
        }
        return matches.first { $0.activationPolicy == .regular } ?? matches.first
    }

    /// Pure matching rule behind `isRunning`. With a saved bundle id only the bundle id counts (case
    /// insensitive), so an unrelated app with the same name is never taken for it. Without one the saved name
    /// is compared with the process's localized name and with its bundle's file name (without ".app").
    public static func matches(_ app: AppRef, bundleID: String?, localizedName: String?,
                               bundleFileName: String?) -> Bool {
        if let wanted = app.bundleID, !wanted.isEmpty {
            return bundleID?.caseInsensitiveCompare(wanted) == .orderedSame
        }
        let wanted = bareName(app.name).lowercased()
        guard !wanted.isEmpty else { return false }
        if let localizedName, localizedName.lowercased() == wanted { return true }
        if let bundleFileName, bareName(bundleFileName).lowercased() == wanted { return true }
        return false
    }

    private static func bareName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func findByName(_ name: String, bundleID: String?) -> URL? {
        let bare = Self.bareName(name)
        guard !bare.isEmpty, !bare.contains("/") else { return nil }
        let fileName = bare + ".app"
        for directory in searchDirectories {
            // Compare file names without regard to case and return the real spelling. When the folder cannot
            // be listed or has no such entry, still try the exact path.
            var names = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.lowercased() == fileName.lowercased() }
                .sorted { ($0 == fileName ? 0 : 1, $0) < ($1 == fileName ? 0 : 1, $1) }
            if names.isEmpty { names = [fileName] }
            for entry in names {
                let candidate = directory.appendingPathComponent(entry, isDirectory: true)
                if isDirectory(candidate), bundleAgrees(candidate, bundleID: bundleID) { return candidate }
            }
        }
        return nil
    }

    private func bundleAgrees(_ url: URL, bundleID: String?) -> Bool {
        guard let expected = bundleID, !expected.isEmpty else { return true }
        guard let actual = Bundle(url: url)?.bundleIdentifier else { return true }
        return actual.caseInsensitiveCompare(expected) == .orderedSame
    }

    // MARK: Settling (pure)

    /// True when the window frames have not changed for `settleTime` seconds as of `now`.
    /// `history` is in time order. The state counts from the first sample of the unchanged run at its end, so
    /// a new, closed or resized window starts the wait again. The order of the frames inside a sample does not
    /// matter and differences up to `tolerance` points are ignored. False for an empty history.
    public static func isSettled(frames history: [FrameSample], now: TimeInterval, settleTime: TimeInterval,
                                 tolerance: CGFloat = 0.5) -> Bool {
        guard let last = history.last else { return false }
        var runStart = last.time
        var index = history.count - 2
        while index >= 0, sameFrames(history[index].frames, last.frames, tolerance: tolerance) {
            runStart = history[index].time
            index -= 1
        }
        return now - runStart >= settleTime
    }

    static func sameFrames(_ a: [CGRect], _ b: [CGRect], tolerance: CGFloat) -> Bool {
        guard a.count == b.count else { return false }
        func order(_ x: CGRect, _ y: CGRect) -> Bool {
            if x.minX != y.minX { return x.minX < y.minX }
            if x.minY != y.minY { return x.minY < y.minY }
            if x.width != y.width { return x.width < y.width }
            return x.height < y.height
        }
        for (x, y) in zip(a.sorted(by: order), b.sorted(by: order)) {
            if abs(x.minX - y.minX) > tolerance || abs(x.minY - y.minY) > tolerance
                || abs(x.width - y.width) > tolerance || abs(x.height - y.height) > tolerance {
                return false
            }
        }
        return true
    }

    // MARK: Launching

    /// Opens the app if it is not running and waits as described by `options`.
    /// An app that is already running is not touched: the result is `.alreadyRunning` with its current
    /// window count (restore decides what to do about missing windows).
    public func launch(_ app: AppRef, options: LaunchOptions = LaunchOptions()) async -> LaunchResult {
        let start = Self.now()
        var result = LaunchResult(app: app, status: .notFound)

        if let running = isRunning(app) {
            let pid = running.processIdentifier
            let (snapshot, system) = await offMain { (Self.readSnapshot(pid: pid), Self.normalWindowCount(pid: pid)) }
            result.status = .alreadyRunning
            result.pid = pid
            result.windowCount = snapshot.frames.count
            result.systemWindowCount = system
            result.timings = LaunchResult.Timings(launchCall: 0, axReady: snapshot.axReady ? 0 : nil,
                                                  firstWindow: snapshot.frames.isEmpty ? nil : 0,
                                                  total: Self.now() - start)
            return result
        }

        guard let url = resolveURL(for: app) else { return result }
        guard AXPermission.isTrusted() else {
            result.status = .failed("Accessibility permission is not granted, so the windows cannot be awaited")
            return result
        }

        // Open the app.
        let configuration = Self.openConfiguration(activates: options.activates)
        let outcome = await open(url, configuration: configuration, timeout: max(options.timeout, 1))
        let launchedAt = Self.now()
        result.timings.launchCall = launchedAt - start
        let running: NSRunningApplication
        switch outcome {
        case .opened(let value):
            running = value
        case .failed(let message):
            result.status = .failed(message)
            result.timings.total = launchedAt - start
            return result
        case .timedOut:
            result.status = .timedOut
            result.timings.total = launchedAt - start
            return result
        }
        result.pid = running.processIdentifier

        await awaitWindows(of: running, url: url, options: options, start: start, result: &result)
        result.timings.total = Self.now() - start
        return result
    }

    /// Launches many apps, at most `concurrency` at the same time, with the same options. Results come back in
    /// the order of `apps`. An app listed twice (same bundle id, or same name without one) is launched once and
    /// both entries get the same result.
    public func launchAll(_ apps: [AppRef], concurrency: Int = 4,
                          options: LaunchOptions = LaunchOptions()) async -> [LaunchResult] {
        await launchAll(apps, concurrency: concurrency, optionsFor: { _ in options })
    }

    /// Like `launchAll(_:concurrency:options:)` with options per app, for example `minWindows` from the number
    /// of windows saved for that app.
    public func launchAll(_ apps: [AppRef], concurrency: Int = 4,
                          optionsFor: @escaping @Sendable (AppRef) -> LaunchOptions) async -> [LaunchResult] {
        guard !apps.isEmpty else { return [] }

        var firstIndex: [String: Int] = [:]
        var unique: [Int] = []
        var duplicateOf: [Int: Int] = [:]
        for (index, app) in apps.enumerated() {
            let key = Self.identityKey(app)
            if let first = firstIndex[key] {
                duplicateOf[index] = first
            } else {
                firstIndex[key] = index
                unique.append(index)
            }
        }

        let limit = max(1, min(concurrency, unique.count))
        var results = [LaunchResult?](repeating: nil, count: apps.count)
        await withTaskGroup(of: (Int, LaunchResult).self) { group in
            var next = 0
            while next < limit {
                let index = unique[next]
                next += 1
                let app = apps[index]
                let options = optionsFor(app)
                group.addTask { [self] in (index, await self.launch(app, options: options)) }
            }
            while let (index, result) = await group.next() {
                results[index] = result
                if next < unique.count {
                    let nextIndex = unique[next]
                    next += 1
                    let app = apps[nextIndex]
                    let options = optionsFor(app)
                    group.addTask { [self] in (nextIndex, await self.launch(app, options: options)) }
                }
            }
        }
        for (index, first) in duplicateOf {
            if var copy = results[first] {
                copy.app = apps[index]
                results[index] = copy
            }
        }
        return results.enumerated().map { index, result in
            result ?? LaunchResult(app: apps[index], status: .failed("Launch did not run"))
        }
    }

    private static func identityKey(_ app: AppRef) -> String {
        if let id = app.bundleID, !id.isEmpty { return "id:" + id.lowercased() }
        return "name:" + bareName(app.name).lowercased()
    }

    // MARK: Waiting for windows

    private enum Ending { case enough, timedOut, quit, cancelled, quietBackgroundApp }

    /// Phase 1: wait for AX and `minWindows`, sending reopens when the app shows no window.
    /// Phase 2: wait for the frames to stop changing. Fills `result` (status, counts, timings).
    private func awaitWindows(of running: NSRunningApplication, url: URL, options: LaunchOptions,
                              start: TimeInterval, result: inout LaunchResult) async {
        let pid = running.processIdentifier
        let wanted = max(options.minWindows, 0)
        let deadline = start + max(options.timeout, Self.pollInterval)
        let isRegularApp = running.activationPolicy == .regular
        let hub = self.hub
        let ownsHub = self.ownsHub

        let watch = LaunchWatch()
        let events = hub.events()
        let pump = Task.detached(priority: .utility) {
            for await event in events where event.pid == pid {
                switch event.kind {
                case .windowCreated, .windowDiscovered, .windowDestroyed, .windowMoved, .windowResized:
                    watch.noteActivity()
                    watch.waker.poke()
                default:
                    break
                }
            }
        }
        defer {
            pump.cancel()
            if ownsHub { hub.stop(pid: pid) }
        }

        var history: [FrameSample] = []
        var snapshot = WindowSnapshot()
        var axReadyAt: TimeInterval?
        var firstWindowAt: TimeInterval?
        var upAt: TimeInterval?   // AX answers and the app finished launching: the reopen clock starts here
        var lastReopenAt: TimeInterval?
        var ending = Ending.timedOut

        let reopenLimit = options.activates ? 1 : (options.activateToReopen ? 2 : 1)

        while true {
            if Task.isCancelled { ending = .cancelled; break }
            if running.isTerminated { ending = .quit; break }

            snapshot = await offMain {
                if !hub.isObserving(pid: pid) { _ = hub.start(pid: pid) }
                return Self.readSnapshot(pid: pid)
            }
            let now = Self.now()
            if snapshot.axReady {
                axReadyAt = axReadyAt ?? now
                history.append(FrameSample(time: now, frames: snapshot.frames))
                if upAt == nil, running.isFinishedLaunching { upAt = now }
            }
            if !snapshot.frames.isEmpty { firstWindowAt = firstWindowAt ?? now }

            let enough = wanted == 0
                ? (snapshot.axReady && running.isFinishedLaunching)
                : snapshot.frames.count >= wanted
            if enough { ending = .enough; break }

            if wanted > 0, let upAt, snapshot.anyWindowCount == 0 {
                if !isRegularApp {
                    // Menu bar and background apps are not expected to open windows; do not poke them.
                    if now - upAt >= options.reopenAfter { ending = .quietBackgroundApp; break }
                } else if result.reopenCount < reopenLimit, now - (lastReopenAt ?? upAt) >= options.reopenAfter {
                    // Only reopen when the window server shows no window either: a window on another Space
                    // is invisible to AX but means the app did create one.
                    let known = await offMain { Self.normalWindowCount(pid: pid) }
                    lastReopenAt = Self.now()
                    if known == 0 {
                        let activate = options.activates || result.reopenCount > 0
                        Self.sendReopen(to: url, activates: activate)
                        result.reopenCount += 1
                        if activate && !options.activates { result.activatedToReopen = true }
                    }
                }
            }

            if now >= deadline { ending = .timedOut; break }
            await watch.waker.wait(upTo: min(Self.pollInterval, deadline - now))
        }

        var settledAt: TimeInterval?
        switch ending {
        case .enough, .quietBackgroundApp:
            result.status = .launched
            if !snapshot.frames.isEmpty {
                settledAt = await awaitSettle(running: running, options: options, watch: watch,
                                              history: &history, snapshot: &snapshot)
            }
        case .timedOut:
            result.status = .timedOut
        case .quit:
            result.status = .failed("The app quit while it was starting")
        case .cancelled:
            result.status = .failed("Cancelled")
        }

        result.windowCount = snapshot.frames.count
        result.systemWindowCount = await offMain { Self.normalWindowCount(pid: pid) }
        result.timings.axReady = axReadyAt.map { $0 - start }
        result.timings.firstWindow = firstWindowAt.map { $0 - start }
        result.timings.settled = settledAt.map { $0 - start }
    }

    /// Returns the time the frames settled, or nil when `maxSettleTime` ran out first.
    private func awaitSettle(running: NSRunningApplication, options: LaunchOptions, watch: LaunchWatch,
                             history: inout [FrameSample], snapshot: inout WindowSnapshot) async -> TimeInterval? {
        let pid = running.processIdentifier
        let begin = Self.now()
        let settleTime = max(options.settleTime, 0)
        let limit = max(options.maxSettleTime, 0)
        while true {
            let now = Self.now()
            if Self.isSettled(frames: history, now: now, settleTime: settleTime),
               watch.quiet(for: settleTime, now: now) {
                return now
            }
            if now - begin >= limit || Task.isCancelled || running.isTerminated { return nil }
            await watch.waker.wait(upTo: min(Self.pollInterval, max(limit - (now - begin), 0.01)))
            snapshot = await offMain { Self.readSnapshot(pid: pid) }
            if snapshot.axReady { history.append(FrameSample(time: Self.now(), frames: snapshot.frames)) }
        }
    }

    // MARK: Opening

    private enum OpenOutcome: @unchecked Sendable {
        case opened(NSRunningApplication)
        case failed(String)
        case timedOut
    }

    private static func openConfiguration(activates: Bool) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        configuration.hides = false
        configuration.addsToRecentItems = false
        return configuration
    }

    /// `openApplication` with a deadline: the completion handler can take very long for a stuck launch.
    private func open(_ url: URL, configuration: NSWorkspace.OpenConfiguration,
                      timeout: TimeInterval) async -> OpenOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<OpenOutcome, Never>) in
            let gate = OnceGate(continuation)
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let app {
                    gate.resume(.opened(app))
                } else {
                    gate.resume(.failed(error?.localizedDescription ?? "The app could not be opened"))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.resume(.timedOut) }
        }
    }

    /// Opening a running app again sends it a reopen event, which makes apps without windows create one.
    private static func sendReopen(to url: URL, activates: Bool) {
        NSWorkspace.shared.openApplication(at: url, configuration: openConfiguration(activates: activates)) { _, _ in }
    }

    // MARK: Reading the app

    struct WindowSnapshot: Sendable {
        /// The app answered a request for its windows.
        var axReady = false
        /// Windows of any kind AX lists (dialogs, splash screens, palettes too).
        var anyWindowCount = 0
        /// Frames of the usable windows: standard windows with a readable, non-empty frame.
        var frames: [CGRect] = []
    }

    static func readSnapshot(pid: pid_t) -> WindowSnapshot {
        let application = AXElement.application(pid: pid)
        let read = application.read(kAXWindowsAttribute)
        guard read.error == .success else { return WindowSnapshot() }
        var windows = ((read.value as? [AnyObject]) ?? []).compactMap { item -> AXElement? in
            CFGetTypeID(item) == AXUIElementGetTypeID()
                ? AXElement(unsafeDowncast(item, to: AXUIElement.self)) : nil
        }
        // Windows on another Space are missing from that list; the main/focused window is still reachable.
        let listedIDs = Set(windows.compactMap(\.windowID))
        windows += AXRemoteWindows.directWindows(pid: pid).filter { !listedIDs.contains($0.key) }.map(\.value)
        var snapshot = WindowSnapshot(axReady: true, anyWindowCount: windows.count)
        for window in windows where AXWindows.isStandardWindow(window) {
            if let frame = window.frame, frame.width > 0, frame.height > 0 { snapshot.frames.append(frame) }
        }
        return snapshot
    }

    /// Normal-level, visible-alpha windows of the process on any Space (including minimized ones), as the
    /// window server reports them. Tiny windows are ignored.
    static func normalWindowCount(pid: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        return list.filter { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? Int, owner == Int(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return false }
            return bounds.width >= 50 && bounds.height >= 50
        }.count
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Runs blocking work (AX and window server calls) off the cooperative thread pool.
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}

// MARK: - Plumbing

/// Resumes a continuation once, whichever of several callers comes first.
private final class OnceGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// A sleep that can be cut short: `wait(upTo:)` returns after the time or when `poke()` is called, also when
/// the poke came a moment before the wait started.
private final class Waker: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var nextID = 0
    private var pending = false

    func poke() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let waiter {
                self.waiter = nil
                return waiter.continuation
            }
            pending = true
            return nil
        }
        continuation?.resume()
    }

    func wait(upTo seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let id = lock.withLock { () -> Int? in
                if pending {
                    pending = false
                    return nil
                }
                nextID += 1
                waiter = (nextID, continuation)
                return nextID
            }
            guard let id else {
                continuation.resume()
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(seconds, 0)) { [weak self] in self?.expire(id) }
        }
    }

    private func expire(_ id: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let waiter, waiter.id == id else { return nil }
            self.waiter = nil
            return waiter.continuation
        }
        continuation?.resume()
    }
}

/// What the hub reported about one app while it launches.
private final class LaunchWatch: @unchecked Sendable {
    let waker = Waker()
    private let lock = NSLock()
    private var lastActivity: TimeInterval?

    func noteActivity() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { lastActivity = now }
    }

    /// No window was created, destroyed, moved or resized during the last `seconds`.
    func quiet(for seconds: TimeInterval, now: TimeInterval) -> Bool {
        guard let last = lock.withLock({ lastActivity }) else { return true }
        return now - last >= seconds
    }
}
