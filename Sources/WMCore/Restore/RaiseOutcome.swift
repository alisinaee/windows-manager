import ApplicationServices
import Foundation

/// How a failed AXRaise is reported.
public enum RaiseOutcome {
    /// "Unsupported" answers mean "another Stage Manager stage" only while Stage Manager is on; otherwise the real error stays a failure.
    public static func result(for raised: AXError, stageManagerOn: Bool) -> RestoreActionResult {
        if stageManagerOn, raised == .actionUnsupported || raised == .attributeUnsupported {
            return .skipped("the window cannot be raised (it sits in another Stage Manager stage or Space)")
        }
        return .failure("the window did not accept AXRaise (AXError \(raised.rawValue))")
    }
}
