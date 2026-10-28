import AppKit
import Combine
import KeyboardShortcuts
import WMCore

/// Registers the global hotkeys: saved profiles, workspace switching and snap-to-zone.
/// Shortcuts are stored by KeyboardShortcuts in UserDefaults; a name without a shortcut does nothing.
@MainActor
final class HotkeyController {
    static let shared = HotkeyController()

    private var registeredProfiles: Set<UUID> = []
    private var sweptStaleDefaults = false
    private var started = false
    private var profilesSink: AnyCancellable?
    private let layoutStore = LayoutStore()

    func start() {
        guard !started else { return }
        started = true
        bind(.nextWorkspace) { WorkspaceController.shared.run(.next) }
        bind(.previousWorkspace) { WorkspaceController.shared.run(.previous) }
        for (i, name) in KeyboardShortcuts.Name.workspaceIndexed.enumerated() {
            bind(name) { WorkspaceController.shared.run(.index(i + 1)) }
        }
        for (i, name) in KeyboardShortcuts.Name.snapZones.enumerated() {
            bind(name) { [weak self] in self?.snapFrontmost(toZone: i) }
        }
        for direction in WindowSizeDirection.allCases {
            bind(.windowSize(direction)) { [weak self] in self?.cycleFrontmost(direction) }
        }
        bind(.moveToNextDisplay) { [weak self] in self?.moveFrontmost(toDisplay: .next) }
        bind(.moveToPreviousDisplay) { [weak self] in self?.moveFrontmost(toDisplay: .previous) }
        syncProfiles()
    }

    /// Registers a global shortcut handler that does nothing while an app on the ignore list is frontmost.
    private func bind(_ name: KeyboardShortcuts.Name, _ action: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: name) {
            guard !Self.isFrontmostIgnored() else { return }
            action()
        }
    }

    private static func isFrontmostIgnored() -> Bool {
        HotkeyIgnoreList.load().contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Registers a handler for each saved profile not yet registered, and follows later changes.
    func syncProfiles() {
        guard let state = AppState.current else {
            // The state is created by the app scene; try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.syncProfiles() }
            return
        }
        // An empty list may mean the profiles failed to load, not that none exist: never wipe hotkeys on that.
        if !sweptStaleDefaults, !state.savedProfiles.isEmpty {
            // Once per launch: shortcuts of profiles deleted in an earlier session were never registered here.
            sweptStaleDefaults = true
            removeStaleProfileDefaults(current: state.savedProfiles.map(\.id))
        }
        if profilesSink == nil {
            profilesSink = state.$savedProfiles.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.registerProfiles()
            }
        }
        registerProfiles()
    }

    private func registerProfiles() {
        guard let profiles = AppState.current?.savedProfiles else { return }
        // Profiles deleted since the last sync: clear their shortcut (this also unregisters it).
        let stale = HotkeyCleanup.staleProfileIDs(registered: registeredProfiles, current: profiles.map(\.id))
        for id in stale.sorted(by: { $0.uuidString < $1.uuidString }) {
            KeyboardShortcuts.reset(.profile(id))
            registeredProfiles.remove(id)
        }
        for profile in profiles where !registeredProfiles.contains(profile.id) {
            registeredProfiles.insert(profile.id)
            let id = profile.id
            // Run by id, looked up at press time, so renames and deletions are honoured and duplicate names are safe.
            bind(.profile(id)) { AppState.current?.run(id: id) }
        }
    }

    /// Clears the stored shortcut and UserDefaults entry of each profile hotkey whose profile is gone.
    private func removeStaleProfileDefaults(current: [UUID]) {
        let defaults = UserDefaults.standard
        let keys = HotkeyCleanup.staleDefaultsKeys(in: defaults.dictionaryRepresentation().keys, current: current)
        for key in keys {
            if let rawName = HotkeyCleanup.shortcutName(forDefaultsKey: key) {
                KeyboardShortcuts.reset(KeyboardShortcuts.Name(rawName))
            }
            defaults.removeObject(forKey: key)
        }
        if !keys.isEmpty {
            AppInfo.logger.notice("Removed \(keys.count) hotkey(s) of deleted profiles")
        }
    }

    // MARK: Snap to zone

    private func snapFrontmost(toZone index: Int) {
        guard AXPermission.isTrusted(), let window = AXWindows.focusedWindow(), let current = window.frame,
              let layouts = try? layoutStore.load(), !layouts.isEmpty else { return }
        let center = CGPoint(x: current.midX, y: current.midY)
        let screen = NSScreen.screens.first { SnapGeometry.topLeftFrame(of: $0.frame).contains(center) } ?? NSScreen.main
        guard let screen, let uuid = Self.displayUUID(screen) else { return }
        guard let layout = layouts.first(where: { $0.displayKey == uuid })
            ?? layouts.first(where: { $0.displayKey == nil }),
              layout.zones.indices.contains(index) else { return }
        let area = SnapGeometry.topLeftFrame(of: screen.visibleFrame)
        let gap = CGFloat(SnapMonitor.loadSettings().gap)
        let frame = LayoutGeometry.frame(of: layout.zones[index].rect, in: area, gap: gap)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = WindowMover.setFrame(window, to: frame)
            AppInfo.logger.notice("Hotkey snap to zone \(index + 1): refused=\(result.refused) minSizeHit=\(result.minSizeHit)")
        }
    }

    // MARK: Size cycling and moving between displays

    private func cycleFrontmost(_ direction: WindowSizeDirection) {
        guard AXPermission.isTrusted(), let window = AXWindows.focusedWindow(), let current = window.frame else { return }
        let displays = Self.topLeftVisibleFrames()
        guard let index = DisplayMove.displayIndex(of: current, in: displays) else { return }
        let frame = WindowSizeCycle.nextFrame(current: current, visible: displays[index], direction: direction)
        setFrameInBackground(window, frame, label: "size \(direction.rawValue)")
    }

    private func moveFrontmost(toDisplay direction: DisplayMoveDirection) {
        guard AXPermission.isTrusted(), let window = AXWindows.focusedWindow(), let current = window.frame else { return }
        guard let frame = DisplayMove.targetFrame(current: current, displays: Self.topLeftVisibleFrames(),
                                                  direction: direction) else { return }
        setFrameInBackground(window, frame, label: "move to \(direction.rawValue) display")
    }

    private func setFrameInBackground(_ window: AXElement, _ frame: CGRect, label: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = WindowMover.setFrame(window, to: frame)
            AppInfo.logger.notice("Hotkey \(label): refused=\(result.refused) minSizeHit=\(result.minSizeHit)")
        }
    }

    /// Visible frame of every display in global top-left coordinates, sorted in the order "next display" uses.
    private static func topLeftVisibleFrames() -> [CGRect] {
        let frames = NSScreen.screens.map { SnapGeometry.topLeftFrame(of: $0.visibleFrame) }
        return DisplayMove.sortedOrder(of: frames).map { frames[$0] }
    }

    private static func displayUUID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cf = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, cf) as String? else { return nil }
        return s.uppercased()
    }
}
