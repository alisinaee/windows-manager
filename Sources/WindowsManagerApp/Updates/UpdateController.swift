import AppKit
import Combine
import Foundation
import Sparkle

/// Sparkle update check. The updater only starts when the bundle has a SUFeedURL in Info.plist,
/// so builds without a real appcast (local `swift run`, unreleased builds) never contact a server.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    /// The appcast URL from Info.plist, or nil when updates are not configured yet.
    let feedURL: String?

    private let controller: SPUStandardUpdaterController
    private var cancellable: AnyCancellable?

    /// True when the user can start a check right now. Republished from Sparkle's KVO-observable
    /// `canCheckForUpdates`, so views that observe this object refresh when it changes.
    @Published private(set) var canCheckForUpdates = false

    var isConfigured: Bool { feedURL != nil }

    /// Shown in place of the update action while `isConfigured` is false.
    static let notConfiguredText = "Updates are not configured yet"

    private init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let trimmed = feed?.trimmingCharacters(in: .whitespacesAndNewlines)
        feedURL = (trimmed?.isEmpty == false) ? trimmed : nil
        controller = SPUStandardUpdaterController(
            startingUpdater: feedURL != nil,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let configured = feedURL != nil
        canCheckForUpdates = configured && controller.updater.canCheckForUpdates
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = configured && value
            }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
