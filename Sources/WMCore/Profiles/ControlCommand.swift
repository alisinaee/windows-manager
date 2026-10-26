import Foundation

/// A user-facing control request: run a profile, capture the workspace under a name, or list profiles.
/// Parsed from a `windowsmanager://` URL or from command line arguments.
public enum ControlCommand: Equatable, Sendable {
    case run(profile: String)
    case capture(name: String)
    case list

    public static let scheme = "windowsmanager"

    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case wrongScheme
        case unknownCommand(String)
        case missingValue(String)
        case usage

        public var description: String {
            switch self {
            case .wrongScheme: return "Not a \(ControlCommand.scheme):// URL"
            case .unknownCommand(let c): return "Unknown command: \(c)"
            case .missingValue(let k): return "Missing value: \(k)"
            case .usage: return "Usage: ctl run <name> | ctl list | ctl capture <name>"
            }
        }
    }

    /// `windowsmanager://run?profile=Work`, `windowsmanager://capture?name=Work`, `windowsmanager://list`.
    public static func parse(url: URL) throws -> ControlCommand {
        guard url.scheme?.lowercased() == scheme else { throw ParseError.wrongScheme }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ParseError.wrongScheme }
        let verb = (comps.host ?? "").lowercased()
        func value(_ key: String) throws -> String {
            let v = comps.queryItems?.first(where: { $0.name == key })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if v.isEmpty { throw ParseError.missingValue(key) }
            return v
        }
        switch verb {
        case "run": return .run(profile: try value("profile"))
        case "capture": return .capture(name: try value("name"))
        case "list": return .list
        default: throw ParseError.unknownCommand(verb)
        }
    }

    /// `["run", "Work"]`, `["list"]`, `["capture", "Work"]`. Extra words join into one name.
    public static func parse(arguments: [String]) throws -> ControlCommand {
        guard let verb = arguments.first?.lowercased() else { throw ParseError.usage }
        let rest = arguments.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        switch verb {
        case "run":
            guard !rest.isEmpty else { throw ParseError.missingValue("profile") }
            return .run(profile: rest)
        case "capture":
            guard !rest.isEmpty else { throw ParseError.missingValue("name") }
            return .capture(name: rest)
        case "list": return .list
        default: throw ParseError.unknownCommand(verb)
        }
    }

    /// The URL that triggers this command; `parse(url:)` round-trips it.
    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .run(let p):
            c.host = "run"; c.queryItems = [URLQueryItem(name: "profile", value: p)]
        case .capture(let n):
            c.host = "capture"; c.queryItems = [URLQueryItem(name: "name", value: n)]
        case .list:
            c.host = "list"
        }
        return c.url!
    }
}
