import AppKit
import Foundation
import Sparkle

/// Sparkle update check. The updater only starts when the bundle has a SUFeedURL in Info.plist,
/// so builds without a real appcast (local `swift run`, unreleased builds) never contact a server.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    /// The appcast URL from Info.plist, or nil when updates are not configured yet.
    let feedURL: String?

    private let controller: SPUStandardUpdaterController

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
    }

    /// True when the user can start a check right now.
    var canCheckForUpdates: Bool {
        isConfigured && controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
