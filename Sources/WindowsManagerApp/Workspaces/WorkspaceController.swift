import AppKit
import Combine
import WMCore

/// Owns the virtual-workspace model and the pieces that act on it (switcher backend, follower, swipe monitor,
/// activation observer). Everything that hides or shows windows is gated by the opt-in `isEnabled` switch
/// (default OFF). Backend calls are synchronous and short, so they run on the main actor.
@MainActor
final class WorkspaceController: ObservableObject {
    static let shared = WorkspaceController()

    static let enabledKey = "virtualWorkspacesEnabled"
    static let naturalSwipeKey = "virtualWorkspacesNaturalSwipe"
    static let followKey = "virtualWorkspacesFollowAppSwitch"

    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var activeID: UUID?
    @Published private(set) var statusText: String?

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? turnOn() : turnOff()
        }
    }
    /// true = natural scrolling direction (the macOS default).
    @Published var naturalSwipe: Bool {
        didSet {
            guard naturalSwipe != oldValue else { return }
            UserDefaults.standard.set(naturalSwipe, forKey: Self.naturalSwipeKey)
            if isEnabled { restartSwipe() }
        }
    }
    @Published var followAppSwitch: Bool {
        didSet {
            guard followAppSwitch != oldValue else { return }
            UserDefaults.standard.set(followAppSwitch, forKey: Self.followKey)
            follower.isEnabled = followAppSwitch
        }
    }

    private var model = WorkspaceModel()
    private let store = WorkspaceModelStore()
    private let backend = SystemWorkspaceBackend()
    private let follower = WorkspaceFollower()
    private var observer: WorkspaceActivationObserver?
    private var swipe: SwipeMonitor?
    private var systemTokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var didRecover = false
    private let log = AppInfo.logger

    private init() {
        let d = UserDefaults.standard
        isEnabled = d.bool(forKey: Self.enabledKey)
        naturalSwipe = d.object(forKey: Self.naturalSwipeKey) as? Bool ?? true
        followAppSwitch = d.object(forKey: Self.followKey) as? Bool ?? true
        follower.isEnabled = followAppSwitch
        do { model = try store.load() ?? WorkspaceModel() } catch {
            statusText = error.localizedDescription
            log.error("Workspace file not loaded: \(error.localizedDescription, privacy: .public)")
        }
        publish()
    }

    // MARK: Launch and permission

    /// Call at launch and whenever Accessibility becomes trusted. Recovers a crashed run (once), then starts
    /// the switching pieces when the switch is on.
    func startIfPossible() {
        guard AXPermission.isTrusted() else { return }
        if !didRecover {
            didRecover = true
            recoverEverything()
        }
        if isEnabled { startPieces() }
    }

    // MARK: Workspace editing

    @discardableResult
    func createWorkspace(named name: String? = nil) -> UUID {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finalName = trimmed.isEmpty ? "Workspace \(model.workspaces.count + 1)" : trimmed
        let ws = Workspace(name: finalName)
        model.workspaces.append(ws)
        if model.activeWorkspaceID == nil { model.activeWorkspaceID = ws.id }
        commit()
        return ws.id
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = model.workspaces.firstIndex(where: { $0.id == id }) else { return }
        model.workspaces[i].name = trimmed
        commit()
    }

    /// Deletes a workspace. Everything hidden is brought back first, so no window is stranded.
    func delete(_ id: UUID) {
        guard model.workspace(id) != nil else { return }
        model.workspaces.removeAll { $0.id == id }
        if model.activeWorkspaceID == id { model.activeWorkspaceID = nil }
        recoverEverything()
        commit()
    }

    /// Assigns the frontmost app (not this app) to the active workspace and removes it from the others.
    func addFrontmostAppToActive() {
        guard let active = model.activeWorkspaceID, let i = model.workspaces.firstIndex(where: { $0.id == active }) else {
            statusText = "Create a workspace first."; return
        }
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, bundle != AppInfo.bundleID else {
            statusText = "No other app is in front."; return
        }
        for k in model.workspaces.indices { model.workspaces[k].apps.removeAll { $0 == bundle } }
        model.workspaces[i].apps.append(bundle)
        statusText = "Added \(bundle) to \(model.workspaces[i].name)."
        commit()
    }

    // MARK: Switching

    func switchTo(_ id: UUID) {
        guard isEnabled else { return }
        let switcher = WorkspaceSwitcher(model: model, system: backend, saver: store)
        follower.isSwitching = true
        defer { follower.switchDidEnd() }
        do {
            let result = try switcher.switchTo(id)
            model = switcher.model
            statusText = result.hasWarnings ? result.warnings.first : nil
        } catch {
            model = switcher.model
            statusText = error.localizedDescription
            log.error("Workspace switch failed: \(error.localizedDescription, privacy: .public)")
        }
        publish()
    }

    func run(_ command: WorkspaceSwitchCommand) {
        guard isEnabled, let target = command.target(in: model) else { return }
        switchTo(target)
    }

    // MARK: On / off

    private func turnOn() {
        statusText = nil
        startIfPossible()
    }

    private func turnOff() {
        stopPieces()
        recoverEverything()
        statusText = nil
    }

    private func startPieces() {
        if observer == nil {
            let obs = WorkspaceActivationObserver { [weak self] event in
                MainActor.assumeIsolated { self?.activated(event) }
            }
            observer = obs
        }
        observer?.start()
        if swipe == nil { startSwipe() }
        if systemTokens.isEmpty { observeSystemEvents() }
    }

    private func stopPieces() {
        observer?.stop()
        observer = nil
        swipe?.stop()
        swipe = nil
        for t in systemTokens { t.center.removeObserver(t.token) }
        systemTokens.removeAll()
    }

    private func startSwipe() {
        let monitor = SwipeMonitor(mapping: SwipeWorkspaceMapping(naturalScroll: naturalSwipe)) { [weak self] command in
            Task { @MainActor in self?.run(command) }
        }
        do {
            try monitor.start()
            swipe = monitor
        } catch {
            statusText = "Swipe gestures unavailable: \(error.localizedDescription)"
            log.error("Swipe monitor not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restartSwipe() {
        swipe?.stop()
        swipe = nil
        startSwipe()
    }

    private func activated(_ event: WorkspaceActivationEvent) {
        guard isEnabled, event.bundleID != AppInfo.bundleID,
              let target = follower.targetWorkspace(for: event, model: model) else { return }
        switchTo(target)
    }

    // MARK: Recovery

    /// Brings back every hidden or parked window and clears the records (launch, switch off, delete).
    private func recoverEverything() {
        let plan = WorkspaceModelStore.recover(model, live: backend.liveWindows())
        let report = VirtualActionApplier.apply(plan.actions, system: backend)
        model = plan.model
        if let first = report.failures.first { statusText = first }
        try? store.save(model)
        publish()
    }

    /// After lock, unlock or wake: windows of the active workspace come back, the rest stay away.
    func reassert() {
        guard isEnabled, AXPermission.isTrusted() else { return }
        let actions = WorkspaceModelStore.reassertActive(model, live: backend.liveWindows())
        guard !actions.isEmpty else { return }
        let report = VirtualActionApplier.apply(actions, system: backend)
        if let first = report.failures.first { statusText = first }
    }

    private func observeSystemEvents() {
        func add(_ center: NotificationCenter, _ name: Notification.Name) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Give the window server a moment to settle after wake or unlock.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    self?.reassert()
                }
            }
            systemTokens.append((center, token))
        }
        add(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification)
        add(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"))
    }

    // MARK: Helpers

    private func commit() {
        do { try store.save(model) } catch { statusText = "Could not save workspaces: \(error.localizedDescription)" }
        publish()
    }

    private func publish() {
        workspaces = model.workspaces
        activeID = model.activeWorkspaceID
    }
}
