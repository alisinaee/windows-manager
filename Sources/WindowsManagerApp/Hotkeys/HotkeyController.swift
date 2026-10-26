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
        KeyboardShortcuts.onKeyDown(for: .nextWorkspace) { WorkspaceController.shared.run(.next) }
        KeyboardShortcuts.onKeyDown(for: .previousWorkspace) { WorkspaceController.shared.run(.previous) }
        for (i, name) in KeyboardShortcuts.Name.workspaceIndexed.enumerated() {
            KeyboardShortcuts.onKeyDown(for: name) { WorkspaceController.shared.run(.index(i + 1)) }
        }
        for (i, name) in KeyboardShortcuts.Name.snapZones.enumerated() {
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in self?.snapFrontmost(toZone: i) }
        }
        syncProfiles()
    }

    /// Registers a handler for each saved profile not yet registered, and follows later changes.
    func syncProfiles() {
        guard let state = AppState.current else {
            // The state is created by the app scene; try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.syncProfiles() }
            return
        }
        if !sweptStaleDefaults {
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
            KeyboardShortcuts.onKeyDown(for: .profile(id)) {
                // Resolve the name at press time so renames and deletions are honoured.
                guard let state = AppState.current,
                      let current = state.savedProfiles.first(where: { $0.id == id }) else { return }
                state.handle(.run(profile: current.name))
            }
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

    private static func displayUUID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cf = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, cf) as String? else { return nil }
        return s.uppercased()
    }
}
