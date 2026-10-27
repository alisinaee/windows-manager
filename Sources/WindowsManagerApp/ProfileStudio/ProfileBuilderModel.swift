import AppKit
import CoreGraphics
import Foundation
import WMCore

/// Where a new draft comes from (plan B2 step 1).
enum StudioStartChoice: Equatable {
    case blank
    case currentWorkspace
    case copyOf(UUID)
    /// Edit a saved profile in place (no start sheet).
    case editExisting(UUID)
}

/// Why a capture produced nothing, as a sentence for people.
struct CaptureFailure: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

enum ProfileBuilderPhase: Equatable {
    case idle
    case starting
    case ready
    case failed(String)
}

/// State of one Builder session: the draft (`DraftSession`), selection, the app library and the derived
/// issue lists. Every edit goes through `ProfileDraftEditor` and is recorded in the undo history.
@MainActor
final class ProfileBuilderModel: ObservableObject {
    @Published private(set) var phase: ProfileBuilderPhase = .idle
    @Published private(set) var session: DraftSession?
    /// Notes from the capture (missing titles, Stage Manager, ...).
    @Published private(set) var startNotes: [String] = []

    // Selection
    @Published var selectedDisplayUUID: String?
    @Published var selectedDesktop: Int?
    @Published var selectedWindowID: UUID?

    // Library
    @Published private(set) var library: [LibraryEntry] = []
    @Published private(set) var isLoadingLibrary = false
    @Published var librarySearch = ""

    // Derived
    @Published private(set) var draftIssues: [DraftCheckIssue] = []
    @Published private(set) var launchIssues: [LaunchIssue] = []
    /// A sentence for people about the last failed action (edit refused, save failed). Cleared by the next success.
    @Published private(set) var lastError: String?
    /// The editable name text; may be empty while typing (an empty name blocks saving).
    @Published private(set) var nameText = ""

    /// The map showing this draft, if any. Set by the owner so Space selection follows structural edits.
    weak var mapModel: ProfileMapModel?

    /// Live sync (P6.67): the draft follows the real windows every 2 s. On for a draft that started from a capture.
    @Published private(set) var isLive = false

    private let store: ProfileStore
    private var connectedDisplays: [DisplayIdentity] = []
    private var installed: [InstalledApp]?
    private var liveTask: Task<Void, Never>?
    /// Windows the user changed or removed by hand: live sync leaves them as the user left them.
    private var manuallyEdited: Set<UUID> = []
    /// Captured windows the user deleted. The scan still sees them while their app is open, so live sync skips them.
    private var dismissedWindows: [WindowSnapshot] = []

    init(store: ProfileStore? = nil) {
        self.store = store ?? AppState.current?.store ?? ProfileStore()
    }

    // MARK: Read access

    var profile: Profile? { session?.profile }
    var isDirty: Bool { session?.isDirty ?? false }
    var canUndo: Bool { session?.canUndo ?? false }
    var canRedo: Bool { session?.canRedo ?? false }
    var isNewProfile: Bool { session?.isNew ?? false }
    var blocksSaving: Bool { nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ProfileDraftCheck.blocksSaving(draftIssues) }
    var errorCount: Int { ProfileDraftCheck.errors(draftIssues).count }
    var warningCount: Int { ProfileDraftCheck.warnings(draftIssues).count }

    /// The library filtered by `librarySearch` (name or bundle id, case-insensitive).
    var filteredLibrary: [LibraryEntry] {
        let q = librarySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return library }
        return library.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q) }
    }
    var runningLibrary: [LibraryEntry] { filteredLibrary.filter(\.isRunning) }
    var installedLibrary: [LibraryEntry] { filteredLibrary.filter { !$0.isRunning && $0.isInstalled } }
    /// Apps that already have a window or a launch-order entry in the draft.
    var appsInProfile: [AppRef] { profile?.apps ?? [] }

    // MARK: Starting

    /// Builds the initial draft. Capture and the disk reads happen off the main thread.
    func start(from choice: StudioStartChoice) async {
        phase = .starting
        lastError = nil
        startNotes = []
        let store = self.store
        let existingNames = store.list().map(\.name)
        let displays = await Task.detached { DisplayMap.current() }.value
        connectedDisplays = displays

        switch choice {
        case .blank:
            guard !displays.isEmpty else { return fail("No monitors were found.") }
            let name = ProfileTransfer.uniqueName("New profile", among: existingNames)
            begin(DraftSession.blankProfile(name: name, displays: displays), isNew: true)
        case .currentWorkspace:
            // The Studio normally goes through `captureWorkspace` + `start(fromCapture:)` so people can pick what to keep;
            // this path keeps everything.
            switch await captureWorkspace() {
            case .failure(let failure): return fail(failure.message)
            case .success(let (captured, notes)):
                startNotes = notes
                begin(DraftSession.capturedDraft(captured, existingNames: existingNames), isNew: true, live: true)
            }
        case .copyOf(let id):
            do {
                let source = try await Task.detached { try store.load(id) }.value
                begin(DraftSession.copyProfile(of: source, existingNames: existingNames), isNew: true)
            } catch {
                fail("That profile could not be opened: \(error.localizedDescription)")
            }
        case .editExisting(let id):
            do {
                let source = try await Task.detached { try store.load(id) }.value
                begin(source, isNew: false)
            } catch {
                fail("That profile could not be opened: \(error.localizedDescription)")
            }
        }
        await loadLibrary()
    }

    /// Reads the live workspace into a draft capture, with the Studio's own windows out of the way (`CaptureSession`).
    /// Nothing in the Builder changes.
    func captureWorkspace() async -> Result<(Profile, [String]), CaptureFailure> {
        DebugLog.log("studio", "capture start: current workspace")
        let scan = await CaptureSession.run { CaptureSession.scanWorkspace() }
        let (captured, notes) = await Task.detached { ProfileCapture.makeProfile(name: "Current workspace", from: scan) }.value
        guard !captured.displays.isEmpty else {
            DebugLog.log("studio", "capture failed: no monitors read")
            return .failure(CaptureFailure("The workspace could not be read. Check the permissions in Settings."))
        }
        DebugLog.log("studio", "capture done: \(captured.displays.count) monitors, \(captured.spaces.count) spaces, \(captured.windows.count) windows")
        return .success((captured, notes))
    }

    /// Starts the draft from a capture the user has already filtered (`CaptureSelection.applying`).
    func start(fromCapture captured: Profile, notes: [String]) async {
        phase = .starting
        lastError = nil
        let existingNames = store.list().map(\.name)
        connectedDisplays = await Task.detached { DisplayMap.current() }.value
        startNotes = notes
        begin(DraftSession.capturedDraft(captured, existingNames: existingNames), isNew: true, live: true)
        await loadLibrary()
    }

    /// The background capture behind "New profile" could not run: the Edit pane shows the message and "Back to View".
    func failCapture(_ message: String) {
        fail(message)
    }

    private func fail(_ message: String) {
        session = nil
        phase = .failed(message)
    }

    private func begin(_ initial: Profile, isNew: Bool, live: Bool = false) {
        session = DraftSession(initial: initial, isNew: isNew)
        selectedDisplayUUID = initial.displays.first?.uuid
        selectedDesktop = initial.spaces.first { $0.displayUUID == selectedDisplayUUID && $0.kind == .desktop }?.desktopNumber
        selectedWindowID = nil
        manuallyEdited = []
        dismissedWindows = []
        phase = .ready
        refresh()
        setLive(live)
    }

    // MARK: Library

    /// Scans the installed apps (once per session, off the main thread) and merges them with the running apps.
    func loadLibrary(forceRescan: Bool = false) async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        if installed == nil || forceRescan {
            installed = await Task.detached { InstalledApps.scan() }.value
        }
        rebuildLibrary()
        refresh()
    }

    /// Re-reads the running apps without rescanning the disk.
    func rebuildLibrary() {
        let running: [(name: String, bundleID: String, url: URL?)] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return nil }
            return (name: app.localizedName ?? id, bundleID: id, url: app.bundleURL)
        }
        library = InstalledApps.merge(running: running, installed: installed ?? [])
    }

    /// An `AppRef` for a library row.
    func appRef(for entry: LibraryEntry) -> AppRef { AppRef(bundleID: entry.bundleID, name: entry.name) }

    /// Adds an app from an `.app` bundle chosen with an open panel. Returns the new library row.
    @discardableResult
    func addAppBundle(at url: URL) -> LibraryEntry? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
            lastError = "That is not an app (no bundle identifier)."
            return nil
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        var apps = installed ?? []
        if !InstalledApps.isInstalled(bundleID: id, in: apps) {
            apps.append(InstalledApp(name: name, bundleID: id, url: url.standardizedFileURL))
            installed = apps
        }
        rebuildLibrary()
        refresh()
        return library.first { $0.bundleID.lowercased() == id.lowercased() }
    }

    // MARK: Editing

    /// Runs one edit through `ProfileDraftEditor`. A refused edit leaves the draft alone and sets `lastError`.
    @discardableResult
    func edit<T>(kind: String? = nil, _ body: (inout ProfileDraftEditor) throws -> T) -> T? {
        guard var s = session else { return nil }
        let before = s.profile
        do {
            let result = try s.edit(kind: kind, body)
            session = s
            noteManualEdits(from: before, to: s.profile)
            lastError = nil
            refresh()
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func setName(_ text: String) {
        nameText = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profile?.name else { return }
        edit(kind: "rename") { try $0.setName(trimmed) }
        nameText = text
    }

    func setIcon(_ icon: String) {
        guard var s = session, s.profile.icon != icon else { return }
        s.setIcon(icon)
        session = s
        refresh()
    }

    // Desktops and Spaces
    @discardableResult
    func addDesktop(onDisplay uuid: String, atNumber: Int? = nil) -> Int? {
        guard let n = edit({ try $0.addDesktop(onDisplay: uuid, atNumber: atNumber) }) else { return nil }
        selectedDisplayUUID = uuid
        selectedDesktop = n
        return n
    }

    func deleteDesktop(onDisplay uuid: String, number: Int, moveWindowsTo target: Int?) {
        guard edit({ try $0.deleteDesktop(onDisplay: uuid, number: number, moveWindowsTo: target) }) != nil else { return }
        keepSelectionValid()
        syncMapSelection()
    }

    func moveDesktop(onDisplay uuid: String, number: Int, toNumber new: Int) {
        guard edit({ try $0.moveDesktop(onDisplay: uuid, number: number, toNumber: new) }) != nil else { return }
        if selectedDisplayUUID == uuid, selectedDesktop == number { selectedDesktop = new }
        syncMapSelection()
    }

    /// `⛶ +`: makes the window full screen in a new Space.
    func makeFullScreen(windowID: UUID, afterPosition: Int? = nil) {
        edit { _ = try $0.makeFullScreen(windowID: windowID, afterPosition: afterPosition) }
    }

    func moveFullScreenSpace(onDisplay uuid: String, position: Int, toIndex index: Int) {
        edit { try $0.moveFullScreenSpace(onDisplay: uuid, position: position, toIndex: index) }
    }

    func removeFullScreenSpace(onDisplay uuid: String, position: Int, removal: FullScreenRemoval) {
        edit { try $0.removeFullScreenSpace(onDisplay: uuid, position: position, removal: removal) }
    }

    // Windows
    /// Drop of a library app: a planned window on `desktop` of `display`. Returns the new window id and selects it.
    @discardableResult
    func addWindow(app: AppRef, onDisplay uuid: String, desktop: Int,
                   relativeFrame: CGRect? = nil, zoneName: String? = nil) -> UUID? {
        guard let id = edit({ try $0.addPlannedWindow(app: app, onDisplay: uuid, desktop: desktop,
                                                                       relativeFrame: relativeFrame, zoneName: zoneName) })
        else { return nil }
        selectedWindowID = id
        return id
    }

    /// Move; one entry per drag when the caller records only on drag end, otherwise ticks of the same window coalesce.
    func moveWindow(_ id: UUID, to relativeFrame: CGRect, zoneName: String? = nil) {
        edit(kind: "moveWindow:\(id.uuidString)") { try $0.setRelativeFrame(ofWindow: id, relativeFrame: relativeFrame, zoneName: zoneName) }
    }

    func resizeWindow(_ id: UUID, to relativeFrame: CGRect, zoneName: String? = nil) {
        edit(kind: "resizeWindow:\(id.uuidString)") { try $0.setRelativeFrame(ofWindow: id, relativeFrame: relativeFrame, zoneName: zoneName) }
    }

    /// Dropping on another monitor tile or Space thumbnail.
    func moveWindow(_ id: UUID, toDisplay uuid: String, desktop: Int) {
        edit { try $0.moveWindow(id, toDisplay: uuid, desktop: desktop) }
    }

    func removeWindow(_ id: UUID) {
        guard edit({ try $0.removeWindow(id) }) != nil else { return }
        if selectedWindowID == id { selectedWindowID = nil }
    }

    func setRestore(_ restore: Bool, forWindow id: UUID) {
        edit(kind: "setRestore:\(id.uuidString)") { try $0.setRestore(restore, forWindow: id) }
    }

    func setMinimized(_ minimized: Bool, forWindow id: UUID) {
        edit(kind: "setMinimized:\(id.uuidString)") { try $0.setMinimized(minimized, forWindow: id) }
    }

    func setOptions(_ change: @escaping (inout ProfileOptions) -> Void) {
        edit(kind: "options") { try $0.setOptions(change) }
    }

    func setLaunchPlan(_ plan: LaunchPlan?) {
        edit { try $0.setLaunchPlan(plan) }
    }

    /// Library context menu `Launch only, no window`: a launch-order entry without a window.
    func addLaunchOnly(app: AppRef) {
        var plan = profile?.launchPlan ?? LaunchPlan(mode: .parallel)
        let item = LaunchItem(app: app, wait: .appReady, withoutWindows: true)
        guard !plan.items.contains(where: { $0.id == item.id }) else { return }
        plan.items.append(item)
        setLaunchPlan(plan)
    }

    // MARK: Undo

    func undo() {
        guard var s = session, s.undo() else { return }
        session = s
        forgetDismissedRestored()
        keepSelectionValid()
        refresh()
        syncMapSelection()
    }

    func redo() {
        guard var s = session, s.redo() else { return }
        session = s
        forgetDismissedRestored()
        keepSelectionValid()
        refresh()
        syncMapSelection()
    }

    // MARK: Save and discard

    /// Saves through `ProfileStore`. The name is made unique among the other saved profiles. Returns the stored
    /// profile, or nil with `lastError` set (empty name, blocking issues, disk error).
    @discardableResult
    func save() -> Profile? {
        guard var s = session else { return nil }
        let ownID = s.profile.id
        let others = store.list().filter { $0.id != ownID }.map(\.name)
        do {
            let ready = try s.prepareSave(otherNames: others, connectedDisplays: connectedDisplays)
            let saved = try store.save(ready)
            s.markSaved(saved)
            session = s
            lastError = nil
            refresh()
            AppState.current?.reloadProfiles()
            return saved
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Throws the draft away (the caller asks first when `isDirty`).
    func discard() {
        setLive(false)
        manuallyEdited = []
        dismissedWindows = []
        session = nil
        phase = .idle
        draftIssues = []
        launchIssues = []
        startNotes = []
        lastError = nil
        nameText = ""
        selectedWindowID = nil
        selectedDesktop = nil
        selectedDisplayUUID = nil
    }

    // MARK: Live sync (P6.67)

    /// Turns the live loop on or off. Turning it on takes one scan at once, then one every 2 s while the draft is ready.
    func setLive(_ on: Bool) {
        guard on || isLive else { return }
        liveTask?.cancel()
        liveTask = nil
        isLive = on
        DebugLog.log("studio", "live \(on ? "on" : "off")")
        guard on else { return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let model = self else { return }
                await model.liveTick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// One pass of the loop. The scan and the capture-to-profile step run off the main thread; the merge runs here.
    /// The loop awaits each pass before it sleeps, so a slow scan is never overlapped by the next one.
    private func liveTick() async {
        guard isLive, phase == .ready, session != nil else { return }
        // A click or drag in progress: the next pass catches up, so the drag is never disturbed.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let scan = await CaptureSession.scanNow()
        let scanned = await Task.detached { ProfileCapture.makeProfile(name: "Live", from: scan).0 }.value
        guard isLive, phase == .ready, let draft = session?.profile else { return }
        let outcome = LiveDraftSync.outcome(draft: draft, scanned: scanned, manuallyEdited: manuallyEdited,
                                            dismissed: dismissedWindows)
        dismissedWindows = outcome.stillDismissed
        guard outcome.profile != draft else { return }
        session?.refreshLive(outcome.profile)
        if outcome.changed {
            DebugLog.log("studio", "live sync: +\(outcome.added) -\(outcome.removed) ~\(outcome.updated)")
        }
        refresh()
        mapModel?.load(outcome.profile)
    }

    /// Records what one edit did to the windows: a changed window is the user's now, a removed captured window is
    /// remembered as deleted (so the scan does not bring it back while its app is open).
    private func noteManualEdits(from before: Profile, to after: Profile) {
        guard before != after else { return }
        for window in after.windows where before.windows.first(where: { $0.id == window.id }) != window {
            manuallyEdited.insert(window.id)
        }
        for window in before.windows where !after.windows.contains(where: { $0.id == window.id }) {
            manuallyEdited.remove(window.id)
            if window.origin != .planned { dismissedWindows.append(window) }
        }
    }

    /// Undo or redo can bring a deleted window back: it is no longer dismissed.
    private func forgetDismissedRestored() {
        guard let p = profile else { return }
        dismissedWindows.removeAll { window in p.windows.contains { $0.id == window.id } }
    }

    // MARK: Derived state

    private func refresh() {
        guard let s = session else { return }
        let p = s.profile
        if nameText.trimmingCharacters(in: .whitespacesAndNewlines) != p.name { nameText = p.name }
        draftIssues = s.issues(connectedDisplays: connectedDisplays.isEmpty ? nil : connectedDisplays)
        if let plan = p.launchPlan {
            let ids = installed.map { Set($0.map(\.bundleID)) }
            launchIssues = LaunchSequence.validate(plan: plan, profile: p, installedApps: ids)
        } else {
            launchIssues = []
        }
    }

    /// Points the map at the builder's selected Desktop (Space ids are positional and shift on structural edits).
    private func syncMapSelection() {
        guard let map = mapModel, let p = profile else { return }
        map.load(p)
        guard let uuid = selectedDisplayUUID, let n = selectedDesktop,
              let space = map.index.spaces.first(where: { $0.displayUUID == uuid && $0.kind == .desktop && $0.desktopNumber == n })
        else { return }
        map.selectSpace(space.id)
    }

    private func keepSelectionValid() {
        guard let p = profile else { return }
        if let id = selectedWindowID, !p.windows.contains(where: { $0.id == id }) { selectedWindowID = nil }
        if let d = selectedDisplayUUID, !p.displays.contains(where: { $0.uuid == d }) { selectedDisplayUUID = p.displays.first?.uuid }
        let desktops = p.spaces.filter { $0.displayUUID == selectedDisplayUUID && $0.kind == .desktop }.compactMap(\.desktopNumber)
        if let n = selectedDesktop, !desktops.contains(n) { selectedDesktop = desktops.first }
    }
}
