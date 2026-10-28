import CoreGraphics
import Foundation

// Pure argument helpers for `wm profile` (P6.90). No I/O and no services, so they are unit tested.
// Every failure is a `CLIFailure` with exit code 2 (usage).

public enum ProfileArgs {
    /// "x,y,w,h" (four numbers, global points or fractions) -> CGRect. Width and height must be positive.
    public static func parseRect(_ text: String, flag: String = "frame") throws -> CGRect {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let numbers = parts.compactMap { Double($0) }.filter { $0.isFinite }
        guard parts.count == 4, numbers.count == 4 else {
            throw CLIFailure.usage("\(flag) must be x,y,w,h with four numbers, for example 100,80,900,600.")
        }
        guard numbers[2] > 0, numbers[3] > 0 else {
            throw CLIFailure.usage("\(flag) needs a positive width and height.")
        }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// "key=value" -> (key, value). The value may be empty; only the first "=" splits.
    public static func parseKeyValue(_ text: String) throws -> (key: String, value: String) {
        guard let eq = text.firstIndex(of: "="), eq != text.startIndex else {
            throw CLIFailure.usage("Expected key=value, got \"\(text)\".", hint: "Example: --set restoreSpaces=false")
        }
        let key = String(text[..<eq]).trimmingCharacters(in: .whitespaces)
        let value = String(text[text.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    /// true/false, yes/no, on/off, 1/0 (case-insensitive).
    public static func parseBool(_ text: String, name: String) throws -> Bool {
        switch text.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: throw CLIFailure.usage("\(name) must be true or false, got \"\(text)\".")
        }
    }

    /// A whole number of at least `minimum`.
    public static func parseInt(_ text: String, name: String, minimum: Int = 1) throws -> Int {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)), n >= minimum else {
            throw CLIFailure.usage("\(name) must be a whole number of at least \(minimum), got \"\(text)\".")
        }
        return n
    }

    public static func parseUUID(_ text: String, name: String = "window") throws -> UUID {
        guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespaces)) else {
            throw CLIFailure.usage("\(name) must be a window id (UUID), got \"\(text)\".",
                                   hint: "Run: wm profile show <profile> to list window ids")
        }
        return id
    }

    /// Option keys accepted by `wm profile options --set key=value`.
    public static let optionKeys = [
        "launchMissingApps", "restoreFullScreen", "restoreSpaces", "restoreSpaceOrder",
        "otherApps", "addMissingDesktops",
    ]

    /// Turns `key=value` assignments into one change for `ProfileService.setOptions`. Validates everything first,
    /// so a bad assignment never changes a profile.
    public static func optionChange(_ assignments: [String]) throws -> (inout ProfileOptions) -> Void {
        var changes: [(inout ProfileOptions) -> Void] = []
        for text in assignments {
            let (key, value) = try parseKeyValue(text)
            switch key {
            case "launchMissingApps":
                let b = try parseBool(value, name: key)
                changes.append { (o: inout ProfileOptions) in o.launchMissingApps = b }
            case "restoreFullScreen":
                let b = try parseBool(value, name: key)
                changes.append { (o: inout ProfileOptions) in o.restoreFullScreen = b }
            case "restoreSpaces":
                let b = try parseBool(value, name: key)
                changes.append { (o: inout ProfileOptions) in o.restoreSpaces = b }
            case "restoreSpaceOrder":
                let b = try parseBool(value, name: key)
                changes.append { (o: inout ProfileOptions) in o.restoreSpaceOrder = b }
            case "addMissingDesktops":
                let b = try parseBool(value, name: key)
                changes.append { (o: inout ProfileOptions) in o.addMissingDesktops = b }
            case "otherApps":
                guard let policy = OtherAppsPolicy(rawValue: value) else {
                    throw CLIFailure.usage("otherApps must be leave, hide or quit, got \"\(value)\".")
                }
                changes.append { (o: inout ProfileOptions) in o.otherApps = policy }
            default:
                throw CLIFailure.usage("Unknown option \"\(key)\".",
                                       hint: "Known keys: \(optionKeys.joined(separator: ", ")). Use shortcut for hotkeys.")
            }
        }
        return { (o: inout ProfileOptions) in
            for change in changes { change(&o) }
        }
    }

    /// Grid size for `profile grid`, limited to `GridSpec.limits`.
    public static func parseGrid(columns: String?, rows: String?) throws -> GridSpec {
        guard let columns, let rows else { throw CLIFailure.usage("A grid needs --cols and --rows.") }
        let c = try parseInt(columns, name: "--cols")
        let r = try parseInt(rows, name: "--rows")
        guard GridSpec.limits.contains(c), GridSpec.limits.contains(r) else {
            throw CLIFailure.usage("--cols and --rows must be between \(GridSpec.limits.lowerBound) and \(GridSpec.limits.upperBound).")
        }
        return GridSpec(columns: c, rows: r)
    }
}
