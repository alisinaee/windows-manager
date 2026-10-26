import AppKit
import CoreGraphics
import Foundation

// Tells the app when to look at the monitors again: after the monitor set or arrangement changed, after
// wake and after the screen was unlocked. Like monitor-glue (MIT, https://github.com/erango/monitor-glue),
// a restore is triggered on connect, wake and unlock; the code is our own.

/// Watches display changes, wake and unlock, and calls one handler after a short quiet period (default 1 s).
///
/// - The handler gets the previous snapshot, the new snapshot and `DisplayMap.monitorSetKey` of the new one.
/// - A change of the monitor set or arrangement (uuid, frame or main flag) calls it. A change that only moves
///   the visible frame (Dock size, menu bar auto-hide) does not.
/// - Wake and unlock call it even when nothing changed, because windows may have moved meanwhile. Compare the
///   keys or `lastTriggers` to tell the cases apart.
/// - Triggers inside the quiet period are merged into one call. By default the handler runs on the main queue.
///
/// Start and stop it from the main thread. It needs a running main run loop (any normal app has one).
public final class DisplayWatcher {
    /// What caused a call. Read `lastTriggers` inside the handler.
    public struct Trigger: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// The monitor set or arrangement really changed.
        public static let displays = Trigger(rawValue: 1)
        public static let wake = Trigger(rawValue: 2)
        public static let unlock = Trigger(rawValue: 4)
    }

    public typealias Handler = (_ old: [DisplayIdentity], _ new: [DisplayIdentity], _ monitorSetKey: String) -> Void

    /// Name of the distributed notification the system posts when the screen is unlocked.
    public static let unlockNotificationName = Notification.Name("com.apple.screenIsUnlocked")

    private let debounce: TimeInterval
    private let queue: DispatchQueue
    private let snapshot: () -> [DisplayIdentity]
    private let handler: Handler

    private let lock = NSLock()
    private var running = false
    private var known: [DisplayIdentity] = []
    private var pending: Trigger = []
    private var timer: DispatchWorkItem?
    private var lastFired: Trigger = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// - Parameters:
    ///   - debounce: quiet period in seconds before the handler runs.
    ///   - queue: queue the handler runs on.
    ///   - snapshot: how to read the monitors; replace it in tests.
    public init(debounce: TimeInterval = 1.0, queue: DispatchQueue = .main,
                snapshot: @escaping () -> [DisplayIdentity] = { DisplayMap.current() },
                handler: @escaping Handler) {
        self.debounce = debounce
        self.queue = queue
        self.snapshot = snapshot
        self.handler = handler
    }

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// The triggers behind the most recent handler call (valid inside the handler).
    public var lastTriggers: Trigger {
        lock.lock(); defer { lock.unlock() }
        return lastFired
    }

    /// Takes the first snapshot and starts listening. Does nothing when already running.
    public func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()

        let first = snapshot()
        lock.lock()
        known = first
        lock.unlock()

        let screens = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        var added: [(center: NotificationCenter, token: NSObjectProtocol)] = []
        added.append((screens, screens.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: nil) { [weak self] _ in
            self?.post(.displays)
        }))
        added.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                                       object: nil, queue: nil) { [weak self] _ in
            self?.post(.wake)
        }))
        added.append((distributed, distributed.addObserver(forName: Self.unlockNotificationName,
                                                           object: nil, queue: nil) { [weak self] _ in
            self?.post(.unlock)
        }))
        lock.lock()
        observers = added
        lock.unlock()

        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback,
                                                 Unmanaged.passUnretained(self).toOpaque())
    }

    /// Stops listening and drops a call that is still waiting for the quiet period.
    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let removed = observers
        observers = []
        timer?.cancel()
        timer = nil
        pending = []
        lock.unlock()

        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
        for item in removed { item.center.removeObserver(item.token) }
    }

    /// Registers a trigger and (re)starts the quiet period. Internal so tests can drive it.
    func post(_ trigger: Trigger) {
        lock.lock()
        guard running else { lock.unlock(); return }
        pending.formUnion(trigger)
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fire() }
        timer = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func fire() {
        let new = snapshot()
        lock.lock()
        guard running else { lock.unlock(); return }
        let old = known
        var triggers = pending.subtracting(.displays) // `.displays` is only reported for a real change
        if !Self.sameLayout(old, new) { triggers.insert(.displays) }
        pending = []
        timer = nil
        known = new
        guard !triggers.isEmpty else { lock.unlock(); return }
        lastFired = triggers
        lock.unlock()
        handler(old, new, DisplayMap.monitorSetKey(new))
    }

    /// Same monitors in the same arrangement. Names, scale and visible frames are ignored on purpose.
    static func sameLayout(_ a: [DisplayIdentity], _ b: [DisplayIdentity]) -> Bool {
        guard a.count == b.count else { return false }
        let left = a.sorted { $0.uuid < $1.uuid }
        let right = b.sorted { $0.uuid < $1.uuid }
        for (x, y) in zip(left, right) {
            if x.uuid != y.uuid || x.frame != y.frame || x.isMain != y.isMain { return false }
        }
        return true
    }
}

/// CoreGraphics calls this on the main run loop, first before and then after a display change.
private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
    guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
    Unmanaged<DisplayWatcher>.fromOpaque(userInfo).takeUnretainedValue().post(.displays)
}
