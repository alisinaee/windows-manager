import Foundation

/// A deadline for work that may hang (P6.132). The workspace scan talks to other apps and can block; the Studio window
/// is hidden meanwhile, so a scan that never returns must end with a visible error and the window shown again.
public enum CaptureTimeout {
    /// How long the "New profile" capture may take before it is given up.
    public static let defaultLimit: Duration = .seconds(15)

    /// The message shown when the scan did not finish in time.
    public static let message = "Reading the workspace took too long and was stopped. Try again; if it keeps happening, check the permissions in Settings."

    /// Runs `operation` and returns its value, or nil when `limit` passes first. The operation is not waited for after
    /// the deadline (it may be blocked and cannot be cancelled); its late result is dropped.
    public static func race<T: Sendable>(limit: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()
            Task {
                let value = await operation()
                if once.take() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: limit)
                if once.take() { continuation.resume(returning: nil) }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }
}
