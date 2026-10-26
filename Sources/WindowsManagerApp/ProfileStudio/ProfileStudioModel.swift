import Combine
import Foundation
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
    case edit   // placeholder until the Builder (UI5+)
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
    @Published var selectedID: UUID? { didSet { if oldValue != selectedID { titleChanged(); selectionChangedForCompare() } } }
    @Published var mode: ProfileStudioMode = .view
    /// Names of profiles that could not be read (shown as a warning, the rest still load).
    @Published private(set) var skipped: [String] = []

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

    var onTitleChange: ((String) -> Void)?
    private var compareTask: Task<Void, Never>?
    private var cancellable: AnyCancellable?
    private var observed: ObjectIdentifier?

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
        var built: [ProfileStudioRow] = []
        var failed: [String] = []
        for summary in app.savedProfiles {
            if let profile = try? app.store.load(summary.id) {
                built.append(ProfileStudioRow(id: profile.id, name: profile.name, icon: profile.icon.isEmpty ? Profile.defaultIcon : profile.icon,
                                              windowCount: profile.windows.count, monitorCount: profile.displays.count,
                                              capturedAt: profile.createdAt))
            } else {
                failed.append(summary.name)
            }
        }
        rows = built
        skipped = failed
        if built.isEmpty && !failed.isEmpty {
            state = .failed("Could not read the saved profiles.")
        } else {
            state = built.isEmpty ? .empty : .loaded
        }
        if let selectedID, !built.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        if selectedID == nil { selectedID = built.first?.id }
        titleChanged()
    }

    /// Selects a profile (reloading first so a just-captured profile is found).
    func open(profileID: UUID) {
        mode = .view
        reload()
        if rows.contains(where: { $0.id == profileID }) { selectedID = profileID }
    }

    // MARK: Compare

    func setCompare(_ on: Bool) {
        guard on != isCompareOn else { return }
        isCompareOn = on
        if on { scheduleCompare(delay: .milliseconds(150)) } else { cancelCompare(clear: true) }
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
        if clear {
            liveStatus = nil
            comparePlan = nil
            compareError = nil
        }
    }

    /// Debounced: a burst of selection changes or refreshes runs one scan. The scan itself runs off the main
    /// thread inside the live environment, exactly the one `AppState.run` uses.
    private func scheduleCompare(delay: Duration) {
        compareTask?.cancel()
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
        isComparing = true
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
            } catch {
                guard !Task.isCancelled, self.selectedID == id else { return }
                self.liveStatus = nil
                self.comparePlan = nil
                self.compareError = "Could not compare: \(error.localizedDescription)"
                self.isComparing = false
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
