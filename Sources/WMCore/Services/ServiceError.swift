import Foundation

/// The typed error every WMCore service throws, so the CLI can map it to an exit code and an error code
/// (`notFound` -> 3, `invalid` -> 2, `conflict` -> 1, `failed` -> 1).
public enum ServiceError: Error, Equatable, LocalizedError {
    /// The named profile, window, desktop, app or other object does not exist.
    case notFound(String)
    /// The input is not acceptable (bad value, would make the profile inconsistent).
    case invalid(String)
    /// The request clashes with existing state (duplicate, shortcut already in use).
    case conflict(String)
    /// Anything else (disk, decoding).
    case failed(String)

    public var errorDescription: String? { message }

    public var message: String {
        switch self {
        case .notFound(let m), .invalid(let m), .conflict(let m), .failed(let m): return m
        }
    }

    /// Stable machine code for the JSON envelope.
    public var code: String {
        switch self {
        case .notFound: return "not_found"
        case .invalid: return "invalid"
        case .conflict: return "conflict"
        case .failed: return "failed"
        }
    }

    /// Maps any error from the store or the draft editor to a `ServiceError`.
    public static func wrap(_ error: Error) -> ServiceError {
        if let e = error as? ServiceError { return e }
        if let e = error as? ProfileStoreError {
            switch e {
            case .notFound: return .notFound(e.localizedDescription)
            case .invalidName, .invalidProfile, .unsupportedSchema, .corrupt: return .invalid(e.localizedDescription)
            }
        }
        if let e = error as? ProfileDraftError {
            switch e {
            case .unknownDisplay, .unknownDesktop, .unknownSpace, .unknownWindow:
                return .notFound(e.localizedDescription)
            default: return .invalid(e.localizedDescription)
            }
        }
        return .failed(error.localizedDescription)
    }
}
