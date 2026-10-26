import AppKit
import ApplicationServices
import Foundation

// Watches running apps for window changes through one AXObserver per process.

/// One thing that happened in an app, delivered by `AXObserverHub`.
public struct AXHubEvent: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        // Notifications registered on the application element.
        case windowCreated
        case focusedWindowChanged
        case appActivated
        case appDeactivated
        // Notifications registered on every window element.
        case windowDestroyed
        case windowMoved
        case windowResized
        case windowMiniaturized
        case windowDeminiaturized
        case titleChanged
        // Not AX notifications: workspace events and rescans.
        case appLaunched
        case appTerminated
        /// A window found by a rescan (after a Space change) that the hub did not know yet.
        case windowDiscovered

        /// AX notification name, nil for kinds that are not AX notifications.
        public var notificationName: String? {
            switch self {
            case .windowCreated: return kAXWindowCreatedNotification
            case .focusedWindowChanged: return kAXFocusedWindowChangedNotification
            case .appActivated: return kAXApplicationActivatedNotification
            case .appDeactivated: return kAXApplicationDeactivatedNotification
            case .windowDestroyed: return kAXUIElementDestroyedNotification
            case .windowMoved: return kAXWindowMovedNotification
            case .windowResized: return kAXWindowResizedNotification
            case .windowMiniaturized: return kAXWindowMiniaturizedNotification
            case .windowDeminiaturized: return kAXWindowDeminiaturizedNotification
            case .titleChanged: return kAXTitleChangedNotification
            case .appLaunched, .appTerminated, .windowDiscovered: return nil
            }
        }

        public init?(notification: String) {
            guard let kind = Kind.allCases.first(where: { $0.notificationName == notification }) else { return nil }
            self = kind
        }

        /// Registered on each window element (the others on the application element).
        public var isWindowLevel: Bool {
            switch self {
            case .windowDestroyed, .windowMoved, .windowResized, .windowMiniaturized, .windowDeminiaturized,
                 .titleChanged:
                return true
            default:
                return false
            }
        }

        /// The kinds that come from AX notifications.
        public static var axKinds: Set<Kind> { Set(allCases.filter { $0.notificationName != nil }) }
    }

    public var kind: Kind
    public var pid: pid_t
    /// The window (or, for app activation, the application element). Nil for launch and terminate events.
    /// For `windowDestroyed` the element is already dead; use `windowID`.
    public var element: AXElement?
    /// CGWindowID of the window when known. For `windowDestroyed` it is the id remembered from before.
    public var windowID: CGWindowID?

    public init(kind: Kind, pid: pid_t, element: AXElement? = nil, windowID: CGWindowID? = nil) {
        self.kind = kind
        self.pid = pid
        self.element = element
        self.windowID = windowID
    }
}

/// One AXObserver per app, on the main run loop (common modes, so events also arrive while menus are open
/// or a window is being dragged). Events come through `onEvent` and/or `events()`, always on the main thread.
///
/// Per app it subscribes to window created, focused window changed and app activated / deactivated on the
/// application element, and to destroyed / moved / resized / miniaturized / deminiaturized / title changed
/// on every window. AX only lists windows of the visible Spaces, so windows on other Spaces are subscribed
/// when a rescan finds them (automatic after a Space change, or call `rescanWindows`).
///
/// Safe against apps that quit: AX errors are never fatal, a terminated app is removed on the workspace
/// notification, and events that arrive after `stop(pid:)` are dropped.
///
/// Moved and resized events fire many times per second while a window is dragged; coalesce them in the
/// consumer.
public final class AXObserverHub: @unchecked Sendable {
    public struct Configuration {
        /// Which AX notifications to subscribe to. Default: all of them.
        public var notifications: Set<AXHubEvent.Kind> = AXHubEvent.Kind.axKinds
        /// Which running apps `startWatchingWorkspace` observes. Default: regular apps except ourselves.
        public var appFilter: (NSRunningApplication) -> Bool = AXObserverHub.defaultAppFilter
        /// Look for windows of other Spaces after the active Space changed.
        public var rescanOnSpaceChange: Bool = true
        public var spaceChangeRescanDelay: TimeInterval = 0.35
        /// Wait times before retrying to observe a freshly launched app that is not ready for AX yet.
        public var launchRetryDelays: [TimeInterval] = [0.15, 0.4, 1, 2, 4]

        public init() {}
    }

    /// Regular apps (Dock icon) other than the current process. Accessory apps such as the Dock are left out.
    public static func defaultAppFilter(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }

    /// Called for every event, on the main thread.
    public var onEvent: ((AXHubEvent) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    private let configuration: Configuration
    private let lock = NSLock()
    private var handler: ((AXHubEvent) -> Void)?
    private var registrations: [pid_t: Registration] = [:]
    private var continuations: [UUID: AsyncStream<AXHubEvent>.Continuation] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var isWatchingWorkspace = false
    private var pendingSpaceRescan: DispatchWorkItem?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    deinit {
        shutdown()
    }

    // MARK: Events

    /// A new stream of events. Every call returns an independent stream; it ends when you stop iterating.
    public func events(bufferingPolicy: AsyncStream<AXHubEvent>.Continuation.BufferingPolicy = .unbounded)
        -> AsyncStream<AXHubEvent> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
    }

    private func emit(_ event: AXHubEvent) {
        let (callback, streams) = lock.withLock { (handler, Array(continuations.values)) }
        callback?(event)
        for stream in streams { stream.yield(event) }
    }

    // MARK: Per app

    /// Process ids that are observed now.
    public var observedPIDs: [pid_t] {
        lock.withLock { registrations.keys.sorted() }
    }

    public func isObserving(pid: pid_t) -> Bool {
        lock.withLock { registrations[pid] != nil }
    }

    /// Starts observing an app. `.success` when it is observed (also when it already was). Typical
    /// failures: `.apiDisabled` (no Accessibility permission), `.cannotComplete` (app not ready or gone).
    /// Windows that exist now are subscribed without events; use your own listing as the starting point.
    @discardableResult
    public func start(pid: pid_t) -> AXError {
        if isObserving(pid: pid) { return .success }
        guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { return .invalidUIElement }

        var created: AXObserver?
        let createError = AXObserverCreate(pid, axObserverCallback, &created)
        guard createError == .success, let observer = created else { return createError }

        let app = AXElement.application(pid: pid)
        let registration = Registration(pid: pid, observer: observer, hub: self)
        let refcon = Unmanaged.passRetained(registration).toOpaque()
        registration.refcon = refcon

        // App-level notifications decide whether the app can be observed at all.
        var attempted = 0
        var succeeded = 0
        var firstError: AXError = .success
        for kind in AXHubEvent.Kind.allCases where !kind.isWindowLevel && configuration.notifications.contains(kind) {
            guard let name = kind.notificationName else { continue }
            attempted += 1
            let error = AXObserverAddNotification(observer, app.raw, name as CFString, refcon)
            if error == .success || error == .notificationAlreadyRegistered {
                succeeded += 1
            } else if firstError == .success {
                firstError = error
            }
        }
        if attempted > 0 && succeeded == 0 {
            Unmanaged<Registration>.fromOpaque(refcon).release()
            return firstError == .success ? .failure : firstError
        }

        // Register, unless another thread was faster.
        let alreadyThere = lock.withLock { () -> Bool in
            if registrations[pid] != nil { return true }
            registrations[pid] = registration
            return false
        }
        if alreadyThere {
            Unmanaged<Registration>.fromOpaque(refcon).release()
            return .success
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        subscribeToWindows(of: registration, emitDiscovered: false)
        return .success
    }

    /// Stops observing an app. Safe to call for apps that are not observed or that already quit.
    public func stop(pid: pid_t) {
        let registration = lock.withLock { registrations.removeValue(forKey: pid) }
        guard let registration else { return }
        teardown(registration)
    }

    /// Stops observing every app. The workspace watch (if any) keeps running.
    public func stopAll() {
        let all = lock.withLock { () -> [Registration] in
            let all = Array(registrations.values)
            registrations.removeAll()
            return all
        }
        all.forEach(teardown)
    }

    /// Stops everything: all apps and the workspace watch.
    public func shutdown() {
        stopWatchingWorkspace()
        stopAll()
    }

    private func teardown(_ registration: Registration) {
        let windows = lock.withLock { () -> [AXElement] in
            registration.isActive = false
            return Array(registration.windows.keys)
        }
        // Removing notifications from a quitting app fails; that is fine.
        let app = AXElement.application(pid: registration.pid)
        for kind in AXHubEvent.Kind.allCases where !kind.isWindowLevel {
            if let name = kind.notificationName {
                _ = AXObserverRemoveNotification(registration.observer, app.raw, name as CFString)
            }
        }
        for window in windows {
            for kind in AXHubEvent.Kind.allCases where kind.isWindowLevel {
                if let name = kind.notificationName {
                    _ = AXObserverRemoveNotification(registration.observer, window.raw, name as CFString)
                }
            }
        }
        let source = AXObserverGetRunLoopSource(registration.observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        // The observer callback holds an unretained pointer. Release the extra reference on the next main
        // run loop turn, after any callback that was already running has finished.
        if let refcon = registration.refcon {
            registration.refcon = nil
            DispatchQueue.main.async { Unmanaged<Registration>.fromOpaque(refcon).release() }
        }
    }

    // MARK: Windows

    /// Looks for windows AX lists now that the hub did not know, subscribes to them and emits
    /// `windowDiscovered` for each. Returns them. Call after the person switched Spaces (the hub does it by
    /// itself when `rescanOnSpaceChange` is on).
    @discardableResult
    public func rescanWindows(pid: pid_t) -> [AXElement] {
        guard let registration = lock.withLock({ registrations[pid] }) else { return [] }
        return subscribeToWindows(of: registration, emitDiscovered: true)
    }

    public func rescanAllWindows() {
        for pid in observedPIDs { rescanWindows(pid: pid) }
    }

    @discardableResult
    private func subscribeToWindows(of registration: Registration, emitDiscovered: Bool) -> [AXElement] {
        var found: [AXElement] = []
        for window in AXWindows.windows(ofPID: registration.pid) {
            guard subscribe(window: window, in: registration) else { continue }
            found.append(window)
            if emitDiscovered {
                emit(AXHubEvent(kind: .windowDiscovered, pid: registration.pid, element: window,
                                windowID: windowID(of: window, in: registration)))
            }
        }
        return found
    }

    /// Subscribes the window-level notifications. False when the window was known already or none worked.
    @discardableResult
    private func subscribe(window: AXElement, in registration: Registration) -> Bool {
        let context = lock.withLock { () -> UnsafeMutableRawPointer? in
            registration.isActive && registration.windows[window] == nil ? registration.refcon : nil
        }
        guard let refcon = context else { return false }
        var succeeded = false
        for kind in AXHubEvent.Kind.allCases where kind.isWindowLevel && configuration.notifications.contains(kind) {
            guard let name = kind.notificationName else { continue }
            let error = AXObserverAddNotification(registration.observer, window.raw, name as CFString, refcon)
            if error == .success || error == .notificationAlreadyRegistered { succeeded = true }
        }
        // Without window-level kinds in the configuration the window is still tracked for its id.
        if !AXHubEvent.Kind.allCases.contains(where: { $0.isWindowLevel && configuration.notifications.contains($0) }) {
            succeeded = true
        }
        guard succeeded else { return false }
        return lock.withLock { () -> Bool in
            guard registration.isActive, registration.windows[window] == nil else { return false }
            registration.windows[window] = window.windowID ?? 0
            return true
        }
    }

    private func windowID(of window: AXElement, in registration: Registration) -> CGWindowID? {
        let cached = lock.withLock { registration.windows[window] }
        if let cached, cached != 0 { return cached }
        let fresh = window.windowID
        if let fresh {
            lock.withLock { if registration.windows[window] != nil { registration.windows[window] = fresh } }
        }
        return fresh
    }

    // MARK: Callback entry (main thread)

    fileprivate func handle(_ registration: Registration, element rawElement: AXUIElement, notification: String) {
        guard lock.withLock({ registration.isActive }),
              let kind = AXHubEvent.Kind(notification: notification),
              configuration.notifications.contains(kind) else { return }
        let element = AXElement(rawElement)
        let pid = registration.pid

        switch kind {
        case .windowDestroyed:
            let id = lock.withLock { () -> CGWindowID? in
                let id = registration.windows.removeValue(forKey: element)
                return (id ?? 0) == 0 ? nil : id
            }
            emit(AXHubEvent(kind: kind, pid: pid, element: element, windowID: id))
        case .windowCreated, .focusedWindowChanged:
            // A window can show up here before AXWindows lists it. Subscribe, then report.
            subscribe(window: element, in: registration)
            emit(AXHubEvent(kind: kind, pid: pid, element: element, windowID: windowID(of: element, in: registration)))
        case .appActivated, .appDeactivated:
            emit(AXHubEvent(kind: kind, pid: pid, element: element))
        default:
            emit(AXHubEvent(kind: kind, pid: pid, element: element, windowID: windowID(of: element, in: registration)))
        }
    }

    // MARK: Workspace (launch, terminate, Space change)

    /// Observes `NSWorkspace` launch and terminate notifications: new apps are observed (with retries while
    /// they start up), terminated apps are removed. Also emits `appLaunched` / `appTerminated`.
    /// With `observeRunningApps` the apps running now are started too.
    public func startWatchingWorkspace(observeRunningApps: Bool = true) {
        let alreadyWatching = lock.withLock { () -> Bool in
            if isWatchingWorkspace { return true }
            isWatchingWorkspace = true
            return false
        }
        guard !alreadyWatching else { return }

        let center = NSWorkspace.shared.notificationCenter
        var tokens: [NSObjectProtocol] = []
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                         queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appLaunched(app)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                         queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appTerminated(app)
        })
        if configuration.rescanOnSpaceChange {
            tokens.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                             queue: .main) { [weak self] _ in
                self?.scheduleSpaceRescan()
            })
        }
        lock.withLock { workspaceTokens = tokens }

        if observeRunningApps {
            for app in NSWorkspace.shared.runningApplications where !app.isTerminated && configuration.appFilter(app) {
                start(pid: app.processIdentifier)
            }
        }
    }

    public func stopWatchingWorkspace() {
        let (tokens, pending) = lock.withLock { () -> ([NSObjectProtocol], DispatchWorkItem?) in
            isWatchingWorkspace = false
            let tokens = workspaceTokens
            workspaceTokens = []
            let pending = pendingSpaceRescan
            pendingSpaceRescan = nil
            return (tokens, pending)
        }
        pending?.cancel()
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    private func appLaunched(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        emit(AXHubEvent(kind: .appLaunched, pid: pid))
        guard configuration.appFilter(app) else { return }
        observeWithRetries(pid: pid, attempt: 0)
    }

    private func appTerminated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        stop(pid: pid)
        emit(AXHubEvent(kind: .appTerminated, pid: pid))
    }

    /// A launching app often refuses AX for a moment (`cannotComplete`); try again a few times.
    private func observeWithRetries(pid: pid_t, attempt: Int) {
        guard lock.withLock({ isWatchingWorkspace }),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        let error = start(pid: pid)
        guard !error.isSuccess, error != .apiDisabled, attempt < configuration.launchRetryDelays.count else { return }
        let delay = configuration.launchRetryDelays[attempt]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.observeWithRetries(pid: pid, attempt: attempt + 1)
        }
    }

    private func scheduleSpaceRescan() {
        let item = DispatchWorkItem { [weak self] in self?.rescanAllWindows() }
        let previous = lock.withLock { () -> DispatchWorkItem? in
            let previous = pendingSpaceRescan
            pendingSpaceRescan = item
            return previous
        }
        previous?.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.spaceChangeRescanDelay, execute: item)
    }
}

// MARK: - Plumbing

/// State of one observed app. Mutable fields are guarded by the hub's lock.
private final class Registration {
    let pid: pid_t
    let observer: AXObserver
    weak var hub: AXObserverHub?
    /// Retained pointer to self handed to AX as the callback context; released after teardown.
    var refcon: UnsafeMutableRawPointer?
    var isActive = true
    /// Subscribed windows and their CGWindowID (0 when unknown).
    var windows: [AXElement: CGWindowID] = [:]

    init(pid: pid_t, observer: AXObserver, hub: AXObserverHub) {
        self.pid = pid
        self.observer = observer
        self.hub = hub
    }
}

private let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let registration = Unmanaged<Registration>.fromOpaque(refcon).takeUnretainedValue()
    registration.hub?.handle(registration, element: element, notification: notification as String)
}
