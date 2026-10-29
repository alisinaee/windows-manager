import AppKit
import Combine
import WMCore

/// What the status line of the menu shows.
enum MenuStatus: Equatable {
    case idle
    case running(String)
    case success(String)
    case failure(String)

    var isBusy: Bool { if case .running = self { return true } else { return false } }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var savedProfiles: [ProfileSummary] = []
    @Published private(set) var status: MenuStatus = .idle
    @Published var isNamingCapture = false
    @Published var captureName = ""
    /// Per-profile scope choices for the menu's Run submenu (loaded with the profile list).
    @Published private(set) var scopeChoices: [UUID: [RunScopeChoice]] = [:]
    /// A fresh capture waiting for "Choose what to save…" ticks; nil when none is open.
    @Published var pendingCapture: PendingCapture?
    let store = ProfileStore()
    @Published private(set) var isAccessibilityTrusted: Bool = AXPermission.isTrusted()

    private var pollTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    /// Names shown in the Settings list.
    var profiles: [String] { savedProfiles.map(\.name) }

    private static let debugModeKey = "debugMode"

    /// Debug mode shows the live test panel (Debug window). Remembered across launches.
    @Published var debugMode: Bool = UserDefaults.standard.bool(forKey: AppState.debugModeKey) {
        didSet {
            guard debugMode != oldValue else { return }
            UserDefaults.standard.set(debugMode, forKey: AppState.debugModeKey)
            if debugMode { showDebugWindow() } else { DebugWindowController.shared.close() }
        }
    }

    /// Set by init so URL handling in the app delegate can reach the state.
    static weak var current: AppState?

    /// URL commands that arrived before any AppState existed (the app was launched by the URL).
    /// Drained once at the end of init, after the profile list has loaded.
    static var pendingCommands = ControlCommandQueue()

    init() {
        AppState.current = self
        reloadProfiles()
        // The user grants Accessibility in System Settings and comes back: re-check when we become active.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        drainPendingCommands()
        // Not inside init: creating the SwiftUI window here can trap during layout.
        if debugMode { DispatchQueue.main.async { [weak self] in self?.showDebugWindow() } }
    }

    /// Opens the Debug window. Closing it with its red button turns Debug mode off, so the menu follows the window.
    private func showDebugWindow() {
        let controller = DebugWindowController.shared
        controller.onClose = { [weak self] in self?.debugMode = false }
        controller.show(store: store) { [weak self] in self?.reloadProfiles() }
    }

    /// Runs the queued URL commands in arrival order, each once.
    private func drainPendingCommands() {
        let commands = AppState.pendingCommands.drain()
        guard !commands.isEmpty else { return }
        AppInfo.logger.notice("Running \(commands.count) control URL(s) that arrived before the app was ready")
        reloadProfiles()
        for command in commands { handle(command) }
    }

    /// Re-reads the permissions. Cheap and never shows a dialog.
    func refreshPermissions() {
        let trusted = AXPermission.isTrusted()
        if trusted != isAccessibilityTrusted {
            isAccessibilityTrusted = trusted
            if trusted {
                // Late grant: start what could not start at launch.
                SnapMonitor.shared.startIfPossible()
                WorkspaceController.shared.startIfPossible()
            }
        }
    }

    /// Shows the system Accessibility dialog, then checks once a second (up to a minute) until the grant lands.
    func requestAccessibility() {
        AXPermission.prompt()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refreshPermissions()
                if self.isAccessibilityTrusted { return }
            }
        }
    }

    // MARK: Profiles

    func reloadProfiles() {
        savedProfiles = store.list().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        loadScopeChoices()
    }

    /// Reads each profile off the main thread to list its Desktops and monitors for the Run submenu.
    private func loadScopeChoices() {
        let summaries = savedProfiles
        let store = self.store
        Task { [weak self] in
            let choices: [UUID: [RunScopeChoice]] = await Task.detached(priority: .utility) {
                var result: [UUID: [RunScopeChoice]] = [:]
                for summary in summaries {
                    if let profile = try? store.load(summary.id) { result[summary.id] = RunScopeChoice.choices(for: profile) }
                }
                return result
            }.value
            self?.scopeChoices = choices
        }
    }

    var canAct: Bool { isAccessibilityTrusted && !status.isBusy }

    /// Why an action cannot start now, or nil when it can.
    private var blockReason: String? {
        if !isAccessibilityTrusted { return "Accessibility is not allowed yet" }
        if status.isBusy { return "Busy: another action is running" }
        return nil
    }

    /// True when the action may start. Otherwise the reason is reported. A running task keeps its status
    /// (overwriting it would hide its progress and make Shortcuts stop waiting too early), so while busy the
    /// refusal is only logged.
    private func checkCanStart() -> Bool {
        guard let reason = blockReason else { return true }
        if status.isBusy {
            AppInfo.logger.notice("Refused while busy: \(reason)")
        } else {
            status = .failure(reason)
        }
        return false
    }

    /// Reports a failure that is not about permissions or a running task (for example an unknown name).
    private func report(_ text: String) {
        if status.isBusy { AppInfo.logger.notice("Not shown while busy: \(text)") } else { status = .failure(text) }
    }

    // MARK: URL control

    /// Handles a windowsmanager:// request: run a profile by name, capture under a name, or list.
    func handle(_ command: ControlCommand) {
        switch command {
        case .run(let profile):
            switch ProfileResolver.resolve(profile, in: savedProfiles) {
            case .found(let id): run(id: id)
            case .ambiguous: report("Several profiles are named \(profile): use a unique name")
            case .none: report("No profile named \(profile)")
            }
        case .capture(let name):
            captureName = name
            commitCapture()
        case .list:
            status = .success(savedProfiles.isEmpty ? "No profiles" : "Profiles: " + profiles.joined(separator: ", "))
        }
    }

    // MARK: Run

    /// Runs the profile with this id. Hotkeys and Shortcuts pass the id, so duplicate names never pick the wrong one.
    func run(id: UUID) {
        guard let summary = savedProfiles.first(where: { $0.id == id }) else {
            report("That profile no longer exists")
            return
        }
        run(summary)
    }

    /// Restores a saved profile. The engine is main-actor bound (it awaits every step), so the UI stays
    /// responsive while it runs; the file read happens off the main thread.
    func run(_ summary: ProfileSummary, scope: RestoreScope = .whole) {
        guard checkCanStart() else { return }
        DebugLog.log("run", "start profile=\(summary.name) id=\(summary.id) scope=\(scope.isWhole ? "whole" : "partial")")
        status = .running("Loading \(summary.name)…")
        let store = self.store
        Task { [weak self] in
            do {
                let profile = try await Task.detached(priority: .userInitiated) { try store.load(summary.id) }.value
                let engine = RestoreEngine()
                let report = await engine.run(profile, scope: scope) { event in
                    DebugLog.log("run", "progress \(event.message)")
                    Task { @MainActor in self?.showProgress(event) }
                }
                guard let self else { return }
                let line = "\(profile.name): \(report.summary)"
                DebugLog.log("run", "finished clean=\(report.isClean) \(line)")
                self.status = report.isClean ? .success(line) : .failure(line)
            } catch {
                DebugLog.log("run", "failed \(error.localizedDescription)")
                self?.status = .failure("Could not run \(summary.name): \(error.localizedDescription)")
            }
        }
    }

    private func showProgress(_ event: RestoreProgress) {
        guard status.isBusy else { return }
        switch event {
        case .finished: break
        case .stepFinished: break
        default: status = .running(event.message)
        }
    }

    // MARK: Capture

    func beginCapture() {
        guard checkCanStart() else { return }
        captureName = ""
        isNamingCapture = true
    }

    func cancelCapture() { isNamingCapture = false }

    /// Menu "Choose what to save…": captures now, then lets the user tick monitors, Desktops and windows before saving.
    func beginSelectiveCapture() {
        guard checkCanStart() else { return }
        status = .running("Capturing the workspace…")
        Task { [weak self] in
            let scan = await CaptureSession.run { CaptureSession.scanWorkspace() }
            let (profile, warnings) = ProfileCapture.makeProfile(name: "Capture", from: scan)
            guard let self else { return }
            let stamp = DateFormatter()
            stamp.dateFormat = "HH.mm.ss"
            self.status = .idle
            self.pendingCapture = PendingCapture(
                profile: profile, warningCount: warnings.count,
                selection: CaptureSelection(tree: CaptureSelectionTree(profile: profile)),
                name: "Capture " + stamp.string(from: Date()))
        }
    }

    func cancelSelectiveCapture() { pendingCapture = nil }

    /// Saves the ticked part of the pending capture as a new profile.
    func saveSelectiveCapture() {
        guard let pending = pendingCapture else { return }
        let name = pending.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, pending.selection.hasSelection else { return }
        pendingCapture = nil
        var profile = pending.selection.applying(to: pending.profile)
        let store = self.store
        Task { [weak self] in
            let outcome: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    profile.name = ProfileTransfer.uniqueName(name, among: store.list().map(\.name))
                    let saved = try store.save(profile)
                    return .success("Saved \(saved.name): \(saved.windows.count) window(s), \(saved.apps.count) app(s)")
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let text): self.status = .success(text)
            case .failure(let error): self.status = .failure("Capture failed: \(error.localizedDescription)")
            }
            self.reloadProfiles()
        }
    }

    /// Menu "Capture now (3 s)": names the profile by the time and captures after a short pause, so the menu can close first.
    func captureNow(afterSeconds seconds: Int = 3) {
        let stamp = DateFormatter()
        stamp.dateFormat = "HH.mm.ss"
        captureName = "Capture " + stamp.string(from: Date())
        commitCapture(afterSeconds: seconds)
    }

    /// Scans the workspace off the main thread and saves the result as a profile.
    /// A name already used by another profile gets a number ("Work 2"), so names stay unambiguous.
    /// With `afterSeconds`, the status shows the countdown first and the scan waits for it to end.
    func commitCapture(afterSeconds seconds: Int = 0) {
        let name = captureName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, checkCanStart() else { return }
        isNamingCapture = false
        DebugLog.log("capture", "start name=\(name) delay=\(seconds)s")
        status = .running(seconds > 0 ? "Capturing in \(seconds) s…" : "Capturing \(name)…")
        let store = self.store
        Task { [weak self] in
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds))
                self?.status = .running("Capturing \(name)…")
            }
            let scan = await CaptureSession.run { CaptureSession.scanWorkspace() }
            let outcome: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let (captured, warnings) = ProfileCapture.makeProfile(name: name, from: scan)
                    var profile = captured
                    profile.name = ProfileTransfer.uniqueName(name, among: store.list().map(\.name))
                    let saved = try store.save(profile)
                    var text = "Saved \(saved.name): \(saved.windows.count) window(s), \(saved.apps.count) app(s)"
                    if !warnings.isEmpty { text += " (\(warnings.count) warning(s))" }
                    return .success(text)
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            DebugLog.log("capture", "result \(outcome)")
            switch outcome {
            case .success(let text): self.status = .success(text)
            case .failure(let error): self.status = .failure("Capture failed: \(error.localizedDescription)")
            }
            self.reloadProfiles()
        }
    }
}

/// A capture waiting for the user's ticks (menu "Choose what to save…").
struct PendingCapture {
    var profile: Profile
    var warningCount: Int
    var selection: CaptureSelection
    var name: String
}

/// One entry of the Run submenu: a title and the scope it runs.
struct RunScopeChoice: Identifiable {
    var id: String
    var title: String
    var scope: RestoreScope

    /// Whole profile, then one entry per Desktop ("Desktop N (Monitor)") and, with several monitors, one per monitor.
    static func choices(for profile: Profile) -> [RunScopeChoice] {
        var result = [RunScopeChoice(id: "whole", title: "Whole profile", scope: .whole)]
        let tree = CaptureSelectionTree(profile: profile)
        let multi = profile.displays.count > 1
        for monitor in tree.monitors {
            let name = monitor.display?.name ?? monitor.displayUUID
            for group in monitor.groups {
                guard group.kind == .desktop, let number = group.desktopNumber else { continue }
                result.append(RunScopeChoice(
                    id: "\(monitor.displayUUID)#\(number)", title: multi ? "Desktop \(number) (\(name))" : "Desktop \(number)",
                    scope: RestoreScope(desktops: [SpaceRef(displayUUID: monitor.displayUUID, desktopNumber: number)])))
            }
            if multi {
                result.append(RunScopeChoice(id: "monitor-\(monitor.displayUUID)", title: "Monitor \(name)",
                                             scope: RestoreScope(displays: [monitor.displayUUID])))
            }
        }
        return result
    }
}
