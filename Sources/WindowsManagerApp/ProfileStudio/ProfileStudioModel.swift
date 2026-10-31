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
    @Published var mode: ProfileStudioMode = .view { didSet { if oldValue != mode { DebugLog.log("studio", "mode: \(mode == .edit ? "Edit" : "View")"); titleChanged() } } }
    /// Names of profiles that could not be read (shown as a warning, the rest still load).
    @Published private(set) var skipped: [String] = []

    // MARK: Sidebar

    /// Collapsed or expanded; the user's choice is remembered ("studioSidebarVisible"; expanded by default).
    @Published private(set) var sidebar = StudioSidebarState(
        isVisible: UserDefaults.standard.object(forKey: "studioSidebarVisible") as? Bool ?? true)
    static let narrowWidth = CGFloat(StudioSidebarState.narrowWidth)

    var isSidebarShown: Bool { sidebar.isShown }

    func toggleSidebar() {
        sidebar.toggle()
        UserDefaults.standard.set(sidebar.isVisible, forKey: "studioSidebarVisible")
        DebugLog.log("studio", "sidebar \(isSidebarShown ? "expanded" : "collapsed")")
    }

    func setSidebar(shown: Bool) {
        if shown != isSidebarShown { toggleSidebar() }
    }

    /// Called from `onGeometryChange`, i.e. during layout. Publishing there (even an unchanged value: a mutating call
    /// on a `@Published` struct always publishes) re-renders the split view mid-layout, and AppKit aborts with
    /// "needs another Update Constraints pass" (crash on entering Edit). So: compare, and apply after the pass.
    func contentWidthChanged(_ width: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var next = sidebar
            next.contentWidthChanged(Double(width))
            if next != sidebar { sidebar = next }
            autoInspector(for: width)
        }
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
    /// The part of the profile the Restore preview (and its Run now) covers; `.whole` for the plain preview.
    @Published var previewScope: RestoreScope = .whole

    // MARK: Edit mode (UI7)

    /// The Builder session of Edit mode; nil in View mode.
    @Published private(set) var builder: ProfileBuilderModel? { didSet { titleChanged(); bindBuilder() } }
    /// Mirrors of the draft's history state so the app menu (and the toolbar) can observe them.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var builderCancellable: AnyCancellable?

    private func bindBuilder() {
        builderCancellable = builder?.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.syncHistory(); self?.titleChanged() }
        syncHistory()
    }

    private func syncHistory() {
        let undo = builder?.canUndo ?? false, redo = builder?.canRedo ?? false
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
    }
    /// "Copy of a profile…" from the New profile menu.
    @Published var isCopyPickerPresented = false
    /// "Review capture" popover: unticking windows removes them from the new draft.
    @Published var isReviewCapturePresented = false
    /// The run-shortcut recorder popover next to Run is open.
    @Published var isShortcutEditorPresented = false
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

    var onTitleChange: ((String, String) -> Void)?
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

    /// The map the zoom menu commands act on (set by whichever map host is on screen).
    weak var activeMap: ProfileMapModel?
    /// True while the Studio window is the key window; the app menu items are disabled otherwise.
    @Published private(set) var isFront = false
    private var keyObservers: [AnyCancellable] = []

    init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    let front = Self.isStudioWindow(NSApp.keyWindow)
                    if self?.isFront != front { self?.isFront = front }
                }
                .store(in: &keyObservers)
        }
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

    /// The profile name (the window title); "Profiles" when there is none.
    var windowTitle: String {
        if mode == .edit, let b = builder {
            if !b.nameText.isEmpty { return b.nameText }
            if !b.isNewProfile, let name = selectedRow?.name { return name }   // draft still loading
            return "Untitled profile"
        }
        return selectedRow?.name ?? "Profiles"
    }

    /// "Edited" while the draft has unsaved changes, otherwise the capture date.
    var windowSubtitle: String {
        if mode == .edit, let b = builder {
            if b.isDirty { return "Edited" }
            if b.isNewProfile { return "New profile" }
        }
        guard let row = selectedRow else { return "" }
        return "Captured " + row.capturedAt.formatted(date: .abbreviated, time: .shortened)
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

    /// Runs just before the Studio switches to Edit; the window controller makes room for the Edit layout there.
    var onEnterEdit: (() -> Void)?

    /// "Edit this profile": opens the saved profile in place.
    func startEditing(_ id: UUID) {
        onEnterEdit?()
        let b = ProfileBuilderModel()
        builder = b
        mode = .edit
        titleChanged()
        setCompare(false)
        Task { await b.start(from: .editExisting(id)) }
    }

    /// A new draft session in Edit mode; the caller starts it.
    private func enterNewDraft() -> ProfileBuilderModel {
        onEnterEdit?()
        let b = ProfileBuilderModel()
        builder = b
        mode = .edit
        titleChanged()
        setCompare(false)
        return b
    }

    /// Why the last "New profile" press did nothing; shown under the button until the next press or leaving Edit.
    @Published var newProfileNotice: String?

    /// "New profile": captures the current workspace at once and opens the map with everything kept (no start sheet).
    /// The map pane shows progress until the capture is done. "Review capture" in the New profile menu unticks windows.
    func beginNewProfile() {
        if let why = NewProfileGate.refusal(isEditing: mode == .edit, hasUnsavedChanges: hasUnsavedChanges) {
            DebugLog.log("studio", "new profile refused: \(why)")
            newProfileNotice = why
            return
        }
        newProfileNotice = nil
        DebugLog.log("studio", "new profile: from current workspace")
        let b = enterNewDraft()
        Task { await capture.run(builder: b) }
    }

    /// "Blank on these monitors" from the New profile menu.
    func beginBlankProfile() {
        if let why = NewProfileGate.refusal(isEditing: mode == .edit, hasUnsavedChanges: hasUnsavedChanges) { newProfileNotice = why; return }
        newProfileNotice = nil
        DebugLog.log("studio", "new profile: blank")
        let b = enterNewDraft()
        Task { await b.start(from: .blank) }
    }

    /// "Copy of a profile…" in the menu: opens the picker, or says why not in Edit mode.
    func requestCopyPicker() {
        if let why = NewProfileGate.refusal(isEditing: mode == .edit, hasUnsavedChanges: hasUnsavedChanges) { newProfileNotice = why; return }
        newProfileNotice = nil
        isCopyPickerPresented = true
    }

    /// "Copy of a profile…": the picked saved profile opens as a draft.
    func beginCopy(of id: UUID) {
        if let why = NewProfileGate.refusal(isEditing: mode == .edit, hasUnsavedChanges: hasUnsavedChanges) { newProfileNotice = why; return }
        newProfileNotice = nil
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
        newProfileNotice = nil
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

    func titleChanged() { onTitleChange?(windowTitle, windowSubtitle) }

    // MARK: Inspector

    /// The right-hand Details inspector is open (remembered between launches).
    @Published var isInspectorShown: Bool = UserDefaults.standard.object(forKey: "studioInspectorShown") as? Bool ?? true {
        didSet {
            if applyingAutoInspector { return }
            autoHidInspector = false
            UserDefaults.standard.set(isInspectorShown, forKey: "studioInspectorShown")
        }
    }
    private var applyingAutoInspector = false
    private var autoHidInspector = false
    static let inspectorMinContentWidth: CGFloat = 820

    /// Collapses the inspector when narrow without touching the remembered preference; restores it when wide.
    private func autoInspector(for width: CGFloat) {
        if width < Self.inspectorMinContentWidth {
            guard isInspectorShown else { return }
            applyingAutoInspector = true
            isInspectorShown = false
            applyingAutoInspector = false
            autoHidInspector = true
        } else if autoHidInspector {
            autoHidInspector = false
            applyingAutoInspector = true
            isInspectorShown = UserDefaults.standard.object(forKey: "studioInspectorShown") as? Bool ?? true
            applyingAutoInspector = false
        }
    }

    // MARK: Sidebar row actions (same store / service calls as Settings > Profiles)

    /// Rows can change only in View mode: a profile open in Edit mode is not renamed or deleted underneath the draft.
    var canChangeRows: Bool { mode == .view }
    @Published var renameTarget: ProfileStudioRow?
    @Published var renameText = ""
    @Published var deleteTarget: ProfileStudioRow?
    /// A failed row action, shown as a banner above the map.
    @Published var actionError: String?
    /// Set for a few seconds after a delete so the banner can offer Undo.
    @Published private(set) var deletedName: String?
    private var deletedProfile: Profile?
    private var deleteDismiss: Task<Void, Never>?

    func run(row: ProfileStudioRow) { AppState.current?.run(id: row.id) }

    func beginRename(_ row: ProfileStudioRow) {
        guard canChangeRows else { return }
        renameText = row.name
        renameTarget = row
    }

    func commitRename() {
        guard let target = renameTarget, let app = AppState.current else { return }
        renameTarget = nil
        do {
            _ = try app.store.rename(target.id, to: renameText)
            app.reloadProfiles()
        } catch { actionError = error.localizedDescription }
    }

    func duplicate(_ row: ProfileStudioRow) {
        guard canChangeRows, let app = AppState.current else { return }
        do {
            let copy = try app.store.duplicate(row.id)
            pendingSelectID = copy.id
            app.reloadProfiles()
        } catch { actionError = error.localizedDescription }
    }

    func export(_ row: ProfileStudioRow) {
        guard let app = AppState.current else { return }
        do {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(row.name).json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try app.profileService.exportData(row.id.uuidString).write(to: url, options: .atomic)
        } catch { actionError = error.localizedDescription }
    }

    func requestDelete(_ row: ProfileStudioRow) {
        guard canChangeRows else { return }
        deleteTarget = row
    }

    func confirmDelete() {
        guard let row = deleteTarget, let app = AppState.current else { return }
        deleteTarget = nil
        do {
            let deleted = try app.profileService.delete(row.id.uuidString)
            app.reloadProfiles()
            deletedProfile = deleted
            deletedName = row.name
            deleteDismiss?.cancel()
            deleteDismiss = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { self?.clearDeleted() }
            }
        } catch { actionError = error.localizedDescription }
    }

    func undoDelete() {
        guard let profile = deletedProfile, let app = AppState.current else { return }
        do {
            let saved = try app.profileService.restore(profile)
            pendingSelectID = saved.id
            app.reloadProfiles()
        } catch { actionError = error.localizedDescription }
        clearDeleted()
    }

    func clearDeleted() {
        deleteDismiss?.cancel()
        deletedName = nil
        deletedProfile = nil
    }
}
