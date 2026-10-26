import AppKit
import Combine
import WMCore

/// Owns the virtual-workspace model and the pieces that act on it (switcher backend, follower, swipe monitor,
/// activation observer). Everything that hides or shows windows is gated by the opt-in `isEnabled` switch
/// (default OFF). Switches run on a serial background queue (`isSwitching` is true meanwhile); recovery and
/// reassert wait for the running switch to finish.
@MainActor
final class WorkspaceController: ObservableObject {
    static let shared = WorkspaceController()

    static let enabledKey = "virtualWorkspacesEnabled"
    static let naturalSwipeKey = "virtualWorkspacesNaturalSwipe"
    static let followKey = "virtualWorkspacesFollowAppSwitch"

    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var activeID: UUID?
    @Published private(set) var statusText: String?
    /// true while a switch runs on the switch queue (the menu shows progress).
    @Published private(set) var isSwitching = false

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
    /// Mixed mode: the switcher sees the backend minus full-screen windows and windows of other Spaces.
    private let mixedBackend = FullScreenAwareSystem(base: SystemWorkspaceBackend(), info: SystemMixedModeSpaceInfo())
    private var deferred = DeferredSwitch()
    /// Switches run one at a time here, off the main actor. Only this queue touches the windows while one runs.
    private let switchQueue = DispatchQueue(label: "com.windowsmanager.workspace-switch", qos: .userInitiated)
    private var switchInFlight = false
    /// The newest request made while a switch runs; an older queued request is replaced (latest wins).
    private var queuedSwitch: UUID?
    /// The newest requested target, used as the base for next/previous.
    private var latestRequest: UUID?
    /// Recovery or reassert asked for while a switch ran; done when the switch chain ends.
    private var needsRecovery = false
    private var needsReassert = false
    private let follower = WorkspaceFollower()
    private var observer: WorkspaceActivationObserver?
    private var swipe: SwipeMonitor?
    private var systemTokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var spaceToken: NSObjectProtocol?
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

    /// Asks for a switch. The work runs on `switchQueue`, so the menu never waits for hidden apps.
    /// A request made while a switch runs is queued; only the newest queued request is kept.
    func switchTo(_ id: UUID) {
        guard isEnabled else { return }
        // On a full-screen Space nothing is hidden or shown; the switch waits for a normal desktop.
        guard let id = deferred.request(id, activeSpaceIsFullScreen: SystemMixedModeSpaceInfo.activeSpaceIsFullScreen()) else {
            activeID = deferred.pending
            statusText = "Workspace switch waits until you leave full screen."
            return
        }
        latestRequest = id
        if switchInFlight {
            queuedSwitch = id
            return
        }
        startSwitch(id)
    }

    func run(_ command: WorkspaceSwitchCommand) {
        guard isEnabled else { return }
        var view = model
        if let latest = latestRequest { view.activeWorkspaceID = latest }
        guard let target = command.target(in: view) else { return }
        switchTo(target)
    }

    /// Runs one switch on `switchQueue` with a snapshot of the model. Main actor only.
    private func startSwitch(_ id: UUID) {
        switchInFlight = true
        isSwitching = true
        follower.isSwitching = true
        let input = model
        // NSScreen is a main-thread API: the screen frames are read here, the switch only uses the copy.
        let system = SwitchSystem(base: mixedBackend, screens: CornerParker.screenFrames())
        let saver = store
        switchQueue.async { [weak self] in
            let switcher = WorkspaceSwitcher(model: input, system: system, saver: saver)
            let outcome: Result<WorkspaceSwitchResult, Error>
            do {
                outcome = .success(try switcher.switchTo(id))
            } catch {
                outcome = .failure(error)
            }
            let output = switcher.model
            Task { @MainActor in self?.finishSwitch(output, outcome) }
        }
    }

    /// Back on the main actor after a switch: publish the result, then run whatever was queued.
    private func finishSwitch(_ output: WorkspaceModel, _ outcome: Result<WorkspaceSwitchResult, Error>) {
        // Only the switch's own state comes back; workspace edits made while it ran are kept.
        model.activeWorkspaceID = output.activeWorkspaceID
        model.hiddenRecords = output.hiddenRecords
        if let active = model.activeWorkspaceID, model.workspace(active) == nil { model.activeWorkspaceID = nil }
        switch outcome {
        case .success(let result):
            statusText = result.hasWarnings ? result.warnings.first : nil
        case .failure(let error):
            statusText = error.localizedDescription
            log.error("Workspace switch failed: \(error.localizedDescription, privacy: .public)")
        }
        switchInFlight = false
        isSwitching = false
        follower.switchDidEnd()
        publish()

        if let next = queuedSwitch {
            queuedSwitch = nil
            startSwitch(next)
            return
        }
        latestRequest = nil
        if needsRecovery {
            needsRecovery = false
            needsReassert = false
            recoverEverything()
        } else if needsReassert {
            needsReassert = false
            reassert()
        }
    }

    // MARK: On / off

    private func turnOn() {
        statusText = nil
        startIfPossible()
    }

    private func turnOff() {
        stopPieces()
        queuedSwitch = nil
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
        if spaceToken == nil {
            spaceToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.activeSpaceChanged() }
            }
        }
    }

    /// Leaving a full-screen Space applies the switch that was deferred while on it.
    private func activeSpaceChanged() {
        guard isEnabled, deferred.hasPending else { return }
        let fullScreen = SystemMixedModeSpaceInfo.activeSpaceIsFullScreen()
        guard let target = deferred.activeSpaceChanged(activeSpaceIsFullScreen: fullScreen, appliedWorkspace: model.activeWorkspaceID) else {
            if !deferred.hasPending { publish() }
            return
        }
        switchTo(target)
    }

    private func stopPieces() {
        observer?.stop()
        observer = nil
        swipe?.stop()
        swipe = nil
        deferred.cancel()
        if let t = spaceToken { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        spaceToken = nil
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
        guard !switchInFlight else { needsRecovery = true; return }
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
        guard !switchInFlight else { needsReassert = true; return }
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

    /// The switch backend as seen from `switchQueue`: the mixed-mode backend, with screen frames
    /// captured on the main actor when the switch started.
    private struct SwitchSystem: WorkspaceSystem {
        let base: WorkspaceSystem
        let screens: [CGRect]

        func liveWindows() -> [VirtualLiveWindow] { base.liveWindows() }
        func bundleID(ofPID pid: Int32) -> String? { base.bundleID(ofPID: pid) }
        func hideApp(pid: Int32) -> Bool { base.hideApp(pid: pid) }
        func unhideApp(pid: Int32) -> Bool { base.unhideApp(pid: pid) }
        func frame(ofWindow windowID: UInt32, pid: Int32) -> CGRect? { base.frame(ofWindow: windowID, pid: pid) }
        func setPosition(_ origin: CGPoint, ofWindow windowID: UInt32, pid: Int32) -> Bool {
            base.setPosition(origin, ofWindow: windowID, pid: pid)
        }
        func setFrame(_ frame: CGRect, ofWindow windowID: UInt32, pid: Int32) -> Bool {
            base.setFrame(frame, ofWindow: windowID, pid: pid)
        }
        func screenFrames() -> [CGRect] { screens }
    }

    private func commit() {
        do { try store.save(model) } catch { statusText = "Could not save workspaces: \(error.localizedDescription)" }
        publish()
    }

    private func publish() {
        workspaces = model.workspaces
        activeID = model.activeWorkspaceID
    }
}
