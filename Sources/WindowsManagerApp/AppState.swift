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
    let store = ProfileStore()
    @Published private(set) var isAccessibilityTrusted: Bool = AXPermission.isTrusted()

    private var pollTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    /// Names shown in the Settings list.
    var profiles: [String] { savedProfiles.map(\.name) }

    /// Set by init so URL handling in the app delegate can reach the state.
    static weak var current: AppState?

    init() {
        AppState.current = self
        reloadProfiles()
        // The user grants Accessibility in System Settings and comes back: re-check when we become active.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    /// Re-reads the permissions. Cheap and never shows a dialog.
    func refreshPermissions() {
        let trusted = AXPermission.isTrusted()
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
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
    }

    var canAct: Bool { isAccessibilityTrusted && !status.isBusy }

    // MARK: URL control

    /// Handles a windowsmanager:// request: run a profile by name, capture under a name, or list.
    func handle(_ command: ControlCommand) {
        switch command {
        case .run(let profile):
            guard let match = savedProfiles.first(where: { $0.name.localizedCaseInsensitiveCompare(profile) == .orderedSame }) else {
                status = .failure("No profile named \(profile)")
                return
            }
            run(match)
        case .capture(let name):
            captureName = name
            commitCapture()
        case .list:
            status = .success(savedProfiles.isEmpty ? "No profiles" : "Profiles: " + profiles.joined(separator: ", "))
        }
    }

    // MARK: Run

    /// Restores a saved profile. The engine is main-actor bound (it awaits every step), so the UI stays
    /// responsive while it runs; the file read happens off the main thread.
    func run(_ summary: ProfileSummary) {
        guard canAct else { return }
        status = .running("Loading \(summary.name)…")
        let store = self.store
        Task { [weak self] in
            do {
                let profile = try await Task.detached(priority: .userInitiated) { try store.load(summary.id) }.value
                let engine = RestoreEngine()
                let report = await engine.run(profile) { event in
                    Task { @MainActor in self?.showProgress(event) }
                }
                guard let self else { return }
                let line = "\(profile.name): \(report.summary)"
                self.status = report.isClean ? .success(line) : .failure(line)
            } catch {
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
        guard canAct else { return }
        captureName = ""
        isNamingCapture = true
    }

    func cancelCapture() { isNamingCapture = false }

    /// Scans the workspace off the main thread and saves the result as a profile.
    func commitCapture() {
        let name = captureName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAct, !name.isEmpty else { return }
        isNamingCapture = false
        status = .running("Capturing \(name)…")
        let store = self.store
        Task { [weak self] in
            let outcome: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let (profile, warnings) = ProfileCapture.capture(name: name)
                    let saved = try store.save(profile)
                    var text = "Saved \(saved.name): \(saved.windows.count) window(s), \(saved.apps.count) app(s)"
                    if !warnings.isEmpty { text += " (\(warnings.count) warning(s))" }
                    return .success(text)
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
}
