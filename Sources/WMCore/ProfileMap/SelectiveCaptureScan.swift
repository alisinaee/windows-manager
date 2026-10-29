import Foundation

/// The scan step of "Choose what to save…": a hung scan ends with an error message instead of staying busy forever.
public enum SelectiveCaptureScan {
    /// Maps the timed scan's result (nil when it timed out) to a value or the visible error.
    public static func outcome<T>(_ scan: T?) -> Result<T, CaptureTimeoutFailure> {
        if let scan { return .success(scan) }
        return .failure(CaptureTimeoutFailure(message: CaptureTimeout.message))
    }
}

public struct CaptureTimeoutFailure: Error, Equatable, Sendable {
    public let message: String
}
