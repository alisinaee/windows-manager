import AppKit
import ApplicationServices
import WMCore

/// Watches global mouse and modifier events and runs the snap gesture: hold the modifier while dragging a
/// window to see the zones of the layout on the display under the pointer; release over a zone to place
/// the window there. Needs Accessibility (global event monitors and AX window access).
@MainActor
final class SnapMonitor {
    static let shared = SnapMonitor()
    static let settingsKey = "snapSettings"

    private var controller = SnapController()
    private var monitors: [Any] = []
    private var overlays: [String: SnapOverlayWindow] = [:]
    private var layouts: [WMCore.Layout] = []
    private var element: AXElement?
    private var nextWindowID: UInt64 = 0
    private var currentWindowID: UInt64 = 0
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
        stopTimer()
        _ = controller.cancel()
        hideOverlays()
        element = nil
        isRunning = false
    }

    // MARK: Events

    private func handle(type: NSEvent.EventType, flags nsFlags: NSEvent.ModifierFlags, location: CGPoint) {
        let flags = Self.flags(nsFlags)
        let point = SnapGeometry.topLeftPoint(location)
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .leftMouseDown:
            layouts = (try? store.load()) ?? []
            var window: SnapWindow?
            if !layouts.isEmpty, let el = Self.window(at: point), let frame = el.frame {
                nextWindowID += 1
                currentWindowID = nextWindowID
                element = el
                window = SnapWindow(id: currentWindowID, frame: frame)
            }
            apply(controller.mouseDown(at: point, window: window))
        case .leftMouseDragged:
            guard controller.isActive else { return }
            let frame = controller.needsWindowFrame ? element?.frame : nil
            apply(controller.dragged(to: point, flags: flags, display: display(at: point), windowFrame: frame, at: now))
            updateTimer()
        case .flagsChanged:
            guard controller.isActive else { return }
            apply(controller.flagsChanged(flags, at: point, display: display(at: point), time: now))
        case .leftMouseUp:
            guard controller.isActive else { return }
            apply(controller.mouseUp(at: point, flags: flags, display: display(at: point)))
            stopTimer()
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
            // AX calls can take a while; keep them off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = WindowMover.setFrame(target, to: frame)
                AppInfo.logger.notice("Snap placed window: refused=\(result.refused) minSizeHit=\(result.minSizeHit)")
            }
        }
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
    /// walked up through the parents. Windows of this app are skipped.
    private static func window(at point: CGPoint) -> AXElement? {
        var hit: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(AXElement.systemWide.raw, Float(point.x), Float(point.y), &hit)
        guard err == .success, let hit else { return nil }
        var current: AXElement? = AXElement(hit, timeout: 0.25)
        for _ in 0..<12 {
            guard let el = current else { return nil }
            if el.role == kAXWindowRole as String {
                if el.pid == ProcessInfo.processInfo.processIdentifier { return nil }
                return el
            }
            if let win = el.element(kAXWindowAttribute as String), win.role == kAXWindowRole as String {
                if win.pid == ProcessInfo.processInfo.processIdentifier { return nil }
                return win
            }
            current = el.element(kAXParentAttribute as String)
        }
        return nil
    }
}
