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
    @Published var selectedID: UUID? { didSet { if oldValue != selectedID { titleChanged() } } }
    @Published var mode: ProfileStudioMode = .view
    /// Names of profiles that could not be read (shown as a warning, the rest still load).
    @Published private(set) var skipped: [String] = []

    var onTitleChange: ((String) -> Void)?
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

    func runSelected() {
        guard let id = selectedID else { return }
        AppState.current?.run(id: id)
    }

    func beginCapture() {
        AppState.current?.beginCapture()
    }

    private func titleChanged() { onTitleChange?(windowTitle) }
}
