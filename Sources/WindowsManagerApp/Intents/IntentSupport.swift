import Foundation
import WMCore

/// Runs a control command on the main-actor app state and waits for the outcome text.
@MainActor
enum IntentRunner {
    struct Outcome { let ok: Bool; let text: String }

    static func perform(_ command: ControlCommand) async -> Outcome {
        await perform { $0.handle(command) }
    }

    /// Runs the profile with this id. Shortcuts passes the id it got from ProfileEntity, so names never matter.
    static func runProfile(id: UUID) async -> Outcome {
        await perform { $0.run(id: id) }
    }

    private static func perform(_ start: (AppState) -> Void) async -> Outcome {
        guard let state = AppState.current else {
            return Outcome(ok: false, text: "Windows Manager is not running. Open the app and try again.")
        }
        guard state.isAccessibilityTrusted else {
            return Outcome(ok: false, text: "Windows Manager needs Accessibility permission first.")
        }
        guard !state.status.isBusy else {
            return Outcome(ok: false, text: "Windows Manager is busy with another task.")
        }
        // Shortcuts reads profiles from disk, so the cached list may be stale (renamed, added or deleted).
        state.reloadProfiles()
        start(state)
        // The work continues in a task; wait until the status leaves "running" (max about 2 minutes).
        try? await Task.sleep(for: .milliseconds(100))
        var waited = 0
        while state.status.isBusy && waited < 1200 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        switch state.status {
        case .success(let t): return Outcome(ok: true, text: t)
        case .failure(let t): return Outcome(ok: false, text: t)
        case .running(let t): return Outcome(ok: false, text: "Still working: \(t)")
        case .idle: return Outcome(ok: false, text: "Nothing happened.")
        }
    }
}
