import AppKit
import ApplicationServices
import WMCore

/// Messaging timeout (seconds) for the Accessibility calls of the snap gesture. A hung app under the pointer
/// must not hold up the snap for long.
private let snapAXTimeout: Float = 0.2

/// Watches global mouse and modifier events and runs the snap gesture: hold the modifier while dragging a
/// window to see the zones of the layout on the display under the pointer; release over a zone to place
/// the window there. Needs Accessibility (global event monitors and AX window access).
///
/// Main thread: events, the controller and the overlay. Accessibility hit tests, frame reads and window moves
/// run on `axQueue`, and their results come back to the main thread tagged with a gesture id, so late
/// results of an old gesture are dropped. Layouts are cached and reloaded only when they change.
@MainActor
final class SnapMonitor {
    static let shared = SnapMonitor()
    static let settingsKey = "snapSettings"

    /// Serial: AX work keeps the order it was requested in.
    private let axQueue = DispatchQueue(label: "dev.windowsmanager.snap.ax", qos: .userInitiated)

    private var controller = SnapController()
    private var monitors: [Any] = []
    private var layoutsObserver: NSObjectProtocol?
    private var overlays: [String: SnapOverlayWindow] = [:]
    /// Cached in memory; loaded at start and again on `.layoutsDidChange`.
    private var layouts: [WMCore.Layout] = []
    private var element: AXElement?
    private var nextWindowID: UInt64 = 0
    private var currentWindowID: UInt64 = 0
    private var gestures = SnapGestureClock()
    private var pressPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var timer: Timer?
    private let store = LayoutStore()
    private let log = AppInfo.logger

    private(set) var isRunning = false

    // MARK: Settings

    static func loadSettings() -> SnapSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(SnapSettings.self, from: data) else { return SnapSettings() }
        return settings
    }

    static func saveSettings(_ settings: SnapSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: settingsKey) }
        shared.controller.settings = settings
    }

    // MARK: Start / stop

    /// Starts only when Accessibility is trusted, snapping is enabled and at least one layout exists.
    func startIfPossible() {
        guard !isRunning else { return }
        let settings = Self.loadSettings()
        guard settings.enabled, AXPermission.isTrusted(), let all = try? store.load(), !all.isEmpty else { return }
        start(settings: settings)
    }

    func start(settings: SnapSettings) {
        guard !isRunning else { return }
        controller = SnapController(settings: settings)
        reloadLayouts()
        layoutsObserver = NotificationCenter.default.addObserver(forName: .layoutsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadLayouts() }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            let flags = event.modifierFlags
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handle(type: type, flags: flags, location: location) }
        }) {
            monitors.append(m)
        }
        isRunning = true
        log.notice("Snap monitor started")
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        if let layoutsObserver { NotificationCenter.default.removeObserver(layoutsObserver) }
        layoutsObserver = nil
        gestures.advance()   // Accessibility results still in flight belong to a gesture that is over.
        stopTimer()
        _ = controller.cancel()
        hideOverlays()
        element = nil
        layouts = []
        isRunning = false
    }

    private func reloadLayouts() {
        layouts = (try? store.load()) ?? []
    }

    // MARK: Events

    private func handle(type: NSEvent.EventType, flags nsFlags: NSEvent.ModifierFlags, location: CGPoint) {
        let flags = Self.flags(nsFlags)
        let point = SnapGeometry.topLeftPoint(location)
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .leftMouseDown:
            beginPress(at: point)
        case .leftMouseDragged:
            lastPoint = point
            guard controller.isActive else { return }
            if controller.needsWindowFrame {
                // The window's frame is only needed once the pointer has moved far enough to be a drag.
                guard SnapGestureClock.passedDragThreshold(from: pressPoint, to: point,
                                                           minimumDistance: controller.settings.minimumDragDistance) else { return }
                requestWindowFrame()
                return
            }
            apply(controller.dragged(to: point, flags: flags, display: display(at: point), windowFrame: nil, at: now))
            updateTimer()
        case .flagsChanged:
            guard controller.isActive else { return }
            apply(controller.flagsChanged(flags, at: point, display: display(at: point), time: now))
        case .leftMouseUp:
            gestures.advance()
            stopTimer()
            guard controller.isActive else { return }
            apply(controller.mouseUp(at: point, flags: flags, display: display(at: point)))
        default:
            break
        }
    }

    private func apply(_ output: SnapController.Output) {
        switch output {
        case .none:
            break
        case .stateChanged(let state):
            switch state {
            case .idle, .dragging:
                hideOverlays()
            case .snapping(_, let display, let zoneID):
                showOverlay(display: display, highlighted: zoneID)
            }
        case .cancel:
            hideOverlays()
        case .commit(let id, let frame):
            hideOverlays()
            guard id == currentWindowID, let target = element else { return }
            axQueue.async {
                let result = WindowMover.setFrame(target, to: frame)
                AppInfo.logger.notice("Snap placed window: refused=\(result.refused) minSizeHit=\(result.minSizeHit)")
            }
        }
    }

    // MARK: Press and drag (Accessibility work happens on axQueue)

    /// A press starts a gesture. The controller gets the window once the hit test answers.
    private func beginPress(at point: CGPoint) {
        let gesture = gestures.advance()
        pressPoint = point
        lastPoint = point
        element = nil
        apply(controller.mouseDown(at: point, window: nil))
        // Nothing to find when snapping is off or no layout exists: then no Accessibility call is made.
        guard controller.settings.enabled, !layouts.isEmpty else { return }
        axQueue.async {
            let found = Self.window(at: point)
            let frame = found?.frame
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.windowFound(found, frame: frame, gesture: gesture) }
            }
        }
    }

    private func windowFound(_ found: AXElement?, frame: CGRect?, gesture: UInt64) {
        guard gestures.isCurrent(gesture), let found, let frame else { return }
        nextWindowID += 1
        currentWindowID = nextWindowID
        element = found
        apply(controller.mouseDown(at: pressPoint, window: SnapWindow(id: currentWindowID, frame: frame)))
    }

    /// Reads the dragged window's frame off the main thread; at most one read per gesture is in flight.
    private func requestWindowFrame() {
        guard let target = element else { return }
        let gesture = gestures.current
        guard gestures.beginFrameRead(for: gesture) else { return }
        axQueue.async {
            let frame = target.frame
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.windowFrameRead(frame, of: target, gesture: gesture) }
            }
        }
    }

    private func windowFrameRead(_ frame: CGRect?, of target: AXElement, gesture: UInt64) {
        gestures.finishFrameRead(for: gesture)
        guard gestures.isCurrent(gesture), controller.isActive, element == target, let frame else { return }
        apply(controller.dragged(to: lastPoint, flags: Self.flags(NSEvent.modifierFlags),
                                 display: display(at: lastPoint), windowFrame: frame,
                                 at: ProcessInfo.processInfo.systemUptime))
        updateTimer()
    }

    /// While a drag is on, a timer lets a zone that has been under a still pointer pass the debounce.
    private func updateTimer() {
        guard timer == nil, controller.isActive else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.controller.isActive else { self.stopTimer(); return }
                let point = SnapGeometry.topLeftPoint(NSEvent.mouseLocation)
                let flags = Self.flags(NSEvent.modifierFlags)
                let out = self.controller.tick(flags: flags, at: point, display: self.display(at: point),
                                               time: ProcessInfo.processInfo.systemUptime)
                self.apply(out)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Displays and overlay

    /// The display under `point` (global top-left) with the layout that applies to it, if any.
    private func display(at point: CGPoint) -> SnapDisplay? {
        for screen in NSScreen.screens {
            let frame = SnapGeometry.topLeftFrame(of: screen.frame)
            guard frame.contains(point) else { continue }
            guard let uuid = Self.displayUUID(screen) else { return nil }
            guard let layout = layouts.first(where: { $0.displayKey == uuid.uppercased() })
                ?? layouts.first(where: { $0.displayKey == nil }) else { return nil }
            return SnapDisplay(id: uuid, frame: SnapGeometry.topLeftFrame(of: screen.visibleFrame), layout: layout)
        }
        return nil
    }

    private func showOverlay(display: SnapDisplay, highlighted: UUID?) {
        guard let screen = NSScreen.screens.first(where: { Self.displayUUID($0) == display.id }) else { return }
        let overlay = overlays[display.id] ?? SnapOverlayWindow(screen: screen)
        overlays[display.id] = overlay
        for (id, other) in overlays where id != display.id { other.hide() }
        overlay.show(zonesOf: display.layout, in: display.frame, highlighted: highlighted)
    }

    private func hideOverlays() {
        for overlay in overlays.values { overlay.hide() }
        // Screens may change between gestures; do not keep stale panels around.
        overlays.removeAll()
    }

    private static func displayUUID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cf = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, cf) as String? else { return nil }
        return s.uppercased()
    }

    // MARK: Helpers

    private static func flags(_ ns: NSEvent.ModifierFlags) -> SnapModifierFlags {
        var f: SnapModifierFlags = []
        if ns.contains(.shift) { f.insert(.shift) }
        if ns.contains(.control) { f.insert(.control) }
        if ns.contains(.option) { f.insert(.option) }
        if ns.contains(.command) { f.insert(.command) }
        return f
    }

    /// The AXWindow under a point (global top-left), found with AXUIElementCopyElementAtPosition and then
    /// walked up through the parents. Windows of this app are skipped. Runs on `axQueue`, never on the main thread.
    private nonisolated static func window(at point: CGPoint) -> AXElement? {
        var hit: AXUIElement?
        let system = AXElement(AXUIElementCreateSystemWide(), timeout: snapAXTimeout)
        let err = AXUIElementCopyElementAtPosition(system.raw, Float(point.x), Float(point.y), &hit)
        guard err == .success, let hit else { return nil }
        var current: AXElement? = AXElement(hit, timeout: snapAXTimeout)
        for _ in 0..<12 {
            guard let el = current else { return nil }
            if el.role == kAXWindowRole as String {
                if el.pid == ProcessInfo.processInfo.processIdentifier { return nil }
                return el
            }
            if let win = child(of: el, kAXWindowAttribute as String), win.role == kAXWindowRole as String {
                if win.pid == ProcessInfo.processInfo.processIdentifier { return nil }
                return win
            }
            current = child(of: el, kAXParentAttribute as String)
        }
        return nil
    }

    /// An attribute element with the snap timeout applied (AXElement.element uses the default timeout).
    private nonisolated static func child(of el: AXElement, _ attribute: String) -> AXElement? {
        guard let c = el.element(attribute) else { return nil }
        c.setMessagingTimeout(snapAXTimeout)
        return c
    }
}
