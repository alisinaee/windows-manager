import AppKit
import Combine
import Foundation
import SwiftUI
import WMCore

/// One sidebar row: the summary plus what only the full profile knows.
struct ProfileStudioRow: Identifiable, Hashable {
    let id: UUID
    let name: String
    let icon: String
    let windowCount: Int
    let monitorCount: Int
    let capturedAt: Date
}

enum ProfileStudioMode: Equatable {
    case view
    case edit
}

enum ProfileStudioLoadState: Equatable {
    case loading
    case empty
    case loaded
    case failed(String)
}

/// State of the Profile Studio window. Reloads whenever `AppState.savedProfiles` changes.
@MainActor
final class ProfileStudioModel: ObservableObject {
    @Published private(set) var rows: [ProfileStudioRow] = []
    @Published private(set) var state: ProfileStudioLoadState = .loading
    @Published var selectedID: UUID? { didSet { if oldValue != selectedID { DebugLog.log("studio", "profile selected: \(selectedRow?.name ?? "none")"); titleChanged(); selectionChangedForCompare() } } }
    @Published var mode: ProfileStudioMode = .view { didSet { if oldValue != mode { DebugLog.log("studio", "mode: \(mode == .edit ? "Edit" : "View")") } } }
    /// Names of profiles that could not be read (shown as a warning, the rest still load).
    @Published private(set) var skipped: [String] = []

    // MARK: Sidebar

    /// The user's choice, remembered ("studioSidebarVisible"; expanded by default).
    @Published private(set) var sidebarVisible = UserDefaults.standard.object(forKey: "studioSidebarVisible") as? Bool ?? true
    /// The window content is narrower than `narrowWidth`: the sidebar collapses unless the user expanded it on purpose.
    @Published private(set) var isNarrow = false
    private var userForcedOpen = false
    static let narrowWidth: CGFloat = 760

    var isSidebarShown: Bool { sidebarVisible && (!isNarrow || userForcedOpen) }

    func toggleSidebar() {
        if isSidebarShown {
            sidebarVisible = false
            userForcedOpen = false
        } else {
            sidebarVisible = true
            userForcedOpen = true   // explicit: do not fight it when the window is narrow
        }
        UserDefaults.standard.set(sidebarVisible, forKey: "studioSidebarVisible")
        DebugLog.log("studio", "sidebar \(isSidebarShown ? "expanded" : "collapsed")")
    }

    func contentWidthChanged(_ width: CGFloat) {
        let narrow = width < Self.narrowWidth
        guard narrow != isNarrow else { return }
        isNarrow = narrow
        if !narrow { userForcedOpen = false }
    }

    // MARK: Compare with now (UI3)

    /// "Show what is missing now": the toggle. Off by default because comparing scans the Mac.
    @Published private(set) var isCompareOn = false
    /// What a restore would do now, projected on the selected profile. Nil when Compare is off or not done yet.
    @Published private(set) var liveStatus: ProfileLiveStatus?
    /// The plan behind `liveStatus` (the inspector reads the steps of one window from it).
    @Published private(set) var comparePlan: RestorePlan?
    @Published private(set) var isComparing = false
    @Published private(set) var compareError: String?
    /// The Restore preview sheet is showing.
    @Published var isPreviewPresented = false

    // MARK: Edit mode (UI7)

    /// The Builder session of Edit mode; nil in View mode.
    @Published private(set) var builder: ProfileBuilderModel?
    /// "Copy of a profile…" from the New profile menu.
    @Published var isCopyPickerPresented = false
    /// "Review capture" popover: unticking windows removes them from the new draft.
    @Published var isReviewCapturePresented = false
    /// The background capture behind a new profile ("New profile" starts it at once).
    let capture = CaptureChoiceModel()
    @Published var isSaveSheetPresented = false
    @Published var isLeaveConfirmPresented = false
    @Published var isSwitchConfirmPresented = false
    private var pendingSwitchID: UUID?
    /// "+ Add App" in the Edit toolbar was pressed; the app library UI observes this.
    @Published var isAddAppPresented = false
    /// Runs once after the next successful save (leave Edit mode, close the window).
    private var afterSave: (() -> Void)?

    var onTitleChange: ((String) -> Void)?
    private var compareTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var pendingSelectID: UUID?
    private var cancellable: AnyCancellable?
    private var observed: ObjectIdentifier?
    /// Compare refreshes itself every 3 s while the Studio is key (P6.67).
    private var compareTimer: Task<Void, Never>?
    /// A comparison scan is running (the spinner shows only for the ones a person asked for).
    private var compareInFlight = false
    private var closeCancellable: AnyCancellable?

    init() {
        // Closing the Studio stops the Live sync of its draft (the draft itself stays, as the window is reopened).
        closeCancellable = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .compactMap { $0.object as? NSWindow }
            .filter { Self.isStudioWindow($0) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.builder?.setLive(false) }
    }

    /// True for the Profile Studio window itself (its content is the Studio view).
    static func isStudioWindow(_ window: NSWindow?) -> Bool {
        window?.contentViewController is NSHostingController<ProfileStudioView>
    }

    var selectedRow: ProfileStudioRow? { rows.first { $0.id == selectedID } }

    var windowTitle: String {
        if let name = selectedRow?.name { return "Profiles - \(name)" }
        return "Profiles"
    }

    /// Loads the saved profiles and keeps following `AppState.savedProfiles`.
    func reload() {
        guard let app = AppState.current else {
            rows = []
            state = .failed("The app is not ready yet.")
            return
        }
        if observed != ObjectIdentifier(app) {
            observed = ObjectIdentifier(app)
            cancellable = app.$savedProfiles.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.reload()
            }
        }
        let summaries = app.savedProfiles
        let store = app.store
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> ([ProfileStudioRow], [String]) in
                var built: [ProfileStudioRow] = []
                var failed: [String] = []
                for summary in summaries {
                    if let profile = try? store.load(summary.id) {
                        built.append(ProfileStudioRow(id: profile.id, name: profile.name, icon: profile.icon.isEmpty ? Profile.defaultIcon : profile.icon,
                                                      windowCount: profile.windows.count, monitorCount: profile.displays.count,
                                                      capturedAt: profile.createdAt))
                    } else {
                        failed.append(summary.name)
                    }
                }
                return (built, failed)
            }.value
            guard !Task.isCancelled else { return }
            self?.apply(rows: result.0, failed: result.1)
        }
    }

    private func apply(rows built: [ProfileStudioRow], failed: [String]) {
        rows = built
        skipped = failed
        if built.isEmpty && !failed.isEmpty {
            state = .failed("Could not read the saved profiles.")
        } else {
            state = built.isEmpty ? .empty : .loaded
        }
        if let pending = pendingSelectID {
            pendingSelectID = nil
            if built.contains(where: { $0.id == pending }) { selectedID = pending }
        }
        if let selectedID, !built.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        if selectedID == nil { selectedID = built.first?.id }
        titleChanged()
    }

    /// Selects a profile (reloading first so a just-captured profile is found).
    func open(profileID: UUID) {
        if hasUnsavedChanges {   // never throw a draft away because another window asked for a profile
            reload()
            return
        }
        leaveEdit()
        pendingSelectID = profileID
        reload()
    }

    // MARK: Edit mode

    var hasUnsavedChanges: Bool { mode == .edit && (builder?.isDirty ?? false) }

    /// The View / Edit toggle.
    func requestMode(_ newMode: ProfileStudioMode) {
        guard newMode != mode else { return }
        switch newMode {
        case .view: requestLeaveEdit()
        case .edit: if let id = selectedID { startEditing(id) }
        }
    }

    /// "Edit this profile": opens the saved profile in place.
    func startEditing(_ id: UUID) {
        let b = ProfileBuilderModel()
        builder = b
        mode = .edit
        setCompare(false)
        Task { await b.start(from: .editExisting(id)) }
    }

    /// A new draft session in Edit mode; the caller starts it.
    private func enterNewDraft() -> ProfileBuilderModel {
        let b = ProfileBuilderModel()
        builder = b
        mode = .edit
        setCompare(false)
        return b
    }

    /// "New profile": captures the current workspace at once and opens the map with everything kept (no start sheet).
    /// The map pane shows progress until the capture is done. "Review capture" in the New profile menu unticks windows.
    func beginNewProfile() {
        guard mode == .view else { return }
        DebugLog.log("studio", "new profile: from current workspace")
        let b = enterNewDraft()
        Task { await capture.run(builder: b) }
    }

    /// "Blank on these monitors" from the New profile menu.
    func beginBlankProfile() {
        guard mode == .view else { return }
        DebugLog.log("studio", "new profile: blank")
        let b = enterNewDraft()
        Task { await b.start(from: .blank) }
    }

    /// "Copy of a profile…": the picked saved profile opens as a draft.
    func beginCopy(of id: UUID) {
        guard mode == .view else { return }
        DebugLog.log("studio", "new profile: copy")
        isCopyPickerPresented = false
        let b = enterNewDraft()
        Task { await b.start(from: .copyOf(id)) }
    }

    /// Sidebar selection. In Edit mode with unsaved changes it asks (Save / Discard / Cancel) before switching.
    func requestSelect(_ id: UUID?) {
        guard let id, id != selectedID else { return }
        if mode == .edit {
            if hasUnsavedChanges {
                pendingSwitchID = id
                isSwitchConfirmPresented = true
                return
            }
            leaveEdit()
        }
        selectedID = id
    }

    func confirmSwitch(save: Bool) {
        guard let id = pendingSwitchID else { return }
        pendingSwitchID = nil
        isSwitchConfirmPresented = false
        if save { saveThen { [weak self] in self?.leaveEdit(); self?.selectedID = id } }
        else { leaveEdit(); selectedID = id }
    }

    func cancelSwitch() { pendingSwitchID = nil; isSwitchConfirmPresented = false }

    /// Leaving Edit mode: asks first when there are unsaved changes.
    func requestLeaveEdit() {
        if hasUnsavedChanges { isLeaveConfirmPresented = true } else { leaveEdit() }
    }

    /// Opens the save sheet and runs `then` after a successful save.
    func saveThen(_ then: (() -> Void)?) {
        afterSave = then
        isSaveSheetPresented = true
    }

    func cancelSave() {
        isSaveSheetPresented = false
        afterSave = nil
    }

    func didSave(_ profile: Profile) {
        DebugLog.log("studio", "save profile: \(profile.name)")
        isSaveSheetPresented = false
        reload()
        selectedID = profile.id
        let next = afterSave
        afterSave = nil
        next?()
    }

    /// Throws the draft away and returns to View mode.
    func leaveEdit() {
        builder?.discard()
        builder = nil
        capture.reset()
        isReviewCapturePresented = false
        isSaveSheetPresented = false
        isLeaveConfirmPresented = false
        afterSave = nil
        mode = .view
    }

    // MARK: Compare

    func setCompare(_ on: Bool) {
        guard on != isCompareOn else { return }
        isCompareOn = on
        DebugLog.log("studio", "compare \(on ? "on" : "off")")
        if on {
            scheduleCompare(delay: .milliseconds(150))
            startCompareTimer()
        } else {
            compareTimer?.cancel()
            compareTimer = nil
            cancelCompare(clear: true)
        }
    }

    /// While Compare is on and the Studio is the key window, the comparison is redone every 3 s, quietly (no spinner).
    /// A comparison still running is left to finish.
    private func startCompareTimer() {
        compareTimer?.cancel()
        compareTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.isCompareOn else { return }
                if !self.compareInFlight, !self.isPreviewPresented, Self.isStudioWindow(NSApp.keyWindow) {
                    self.scheduleCompare(delay: .milliseconds(0), showsProgress: false)
                }
            }
        }
    }

    /// Cmd+R, and when the window becomes key again. Does nothing while Compare is off.
    func refreshCompare() {
        guard isCompareOn else { return }
        scheduleCompare(delay: .milliseconds(300))
    }

    private func selectionChangedForCompare() {
        cancelCompare(clear: true)
        if isCompareOn, selectedID != nil { scheduleCompare(delay: .milliseconds(350)) }
    }

    private func cancelCompare(clear: Bool) {
        compareTask?.cancel()
        compareTask = nil
        isComparing = false
        compareInFlight = false
        if clear {
            liveStatus = nil
            comparePlan = nil
            compareError = nil
        }
    }

    /// Debounced: a burst of selection changes or refreshes runs one scan. The scan itself runs off the main
    /// thread inside the live environment, exactly the one `AppState.run` uses.
    private func scheduleCompare(delay: Duration, showsProgress: Bool = true) {
        compareTask?.cancel()
        compareInFlight = false
        guard let id = selectedID else { return }
        guard AppState.current?.isAccessibilityTrusted ?? false else {
            compareTask = nil
            isComparing = false
            liveStatus = nil
            comparePlan = nil
            compareError = "Accessibility is not allowed yet, so the map cannot compare with your Mac. Allow it in System Settings > Privacy & Security > Accessibility, then turn Compare on again."
            return
        }
        compareError = nil
        if showsProgress { isComparing = true }
        compareInFlight = true
        compareTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let app = AppState.current else { return }
            let store = app.store
            do {
                let profile = try await Task.detached(priority: .userInitiated) { try store.load(id) }.value
                guard !Task.isCancelled else { return }
                let plan = await RestoreEngine().preview(profile: profile)
                guard !Task.isCancelled, self.selectedID == id else { return }
                self.comparePlan = plan
                self.liveStatus = ProfileLiveStatus(profile: profile, plan: plan)
                self.compareError = nil
                self.isComparing = false
                self.compareInFlight = false
            } catch {
                guard !Task.isCancelled, self.selectedID == id else { return }
                self.liveStatus = nil
                self.comparePlan = nil
                self.compareError = "Could not compare: \(error.localizedDescription)"
                self.isComparing = false
                self.compareInFlight = false
            }
        }
    }

    func runSelected() {
        guard let id = selectedID else { return }
        AppState.current?.run(id: id)
    }

    func beginCapture() {
        AppState.current?.beginCapture()
    }

    private func titleChanged() { onTitleChange?(windowTitle) }
}
