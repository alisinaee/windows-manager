import Foundation

/// Removes personal data from text that leaves the machine in a bug report.
public struct BugRedactor: Sendable {
    public var home: String
    public var userName: String
    public var hostNames: [String]

    public init(home: String, userName: String, hostNames: [String] = []) {
        self.home = home; self.userName = userName; self.hostNames = hostNames
    }

    /// The redactor for the current user and machine.
    public static var current: BugRedactor {
        let host = ProcessInfo.processInfo.hostName
        let short = host.split(separator: ".").first.map(String.init) ?? host
        return BugRedactor(home: NSHomeDirectory(), userName: NSUserName(), hostNames: [host, short])
    }

    public func redact(_ text: String) -> String {
        var out = text
        // Home first, so the user name inside the path goes with it.
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        out = out.replacingOccurrences(of: "/Users/\(userName)", with: "~")
        out = Self.regexReplace(out, #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>")
        // Window titles: keep app names, drop the title text.
        out = Self.regexReplace(out, #"(window\s+)"(?:[^"\\]|\\.)*""#, "$1\"<title>\"")
        for host in hostNames.sorted(by: { $0.count > $1.count }) where host.count >= 2 {
            out = Self.regexReplace(out, "\\b" + NSRegularExpression.escapedPattern(for: host) + "\\b", "<host>", caseInsensitive: true)
        }
        out = Self.regexReplace(out, #"\b[A-Za-z0-9\-]+\.local\b"#, "<host>")
        if userName.count >= 2 {
            out = Self.regexReplace(out, "\\b" + NSRegularExpression.escapedPattern(for: userName) + "\\b", "<user>", caseInsensitive: true)
        }
        return out
    }

    static func regexReplace(_ s: String, _ pattern: String, _ template: String, caseInsensitive: Bool = false) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

/// Facts about the machine and app, gathered once and then redacted when rendered.
public struct BugReportEnvironment: Sendable, Equatable {
    public var appVersion: String
    public var appBuild: String
    public var macOSVersion: String
    public var hardwareModel: String
    public var displayCount: Int?
    public var desktopCount: Int?
    public var stageManager: Bool?
    public var rearrangeSpaces: Bool?
    public var accessibilityTrusted: Bool?

    public init(appVersion: String = "unknown", appBuild: String = "unknown", macOSVersion: String = "unknown",
                hardwareModel: String = "unknown", displayCount: Int? = nil, desktopCount: Int? = nil,
                stageManager: Bool? = nil, rearrangeSpaces: Bool? = nil, accessibilityTrusted: Bool? = nil) {
        self.appVersion = appVersion; self.appBuild = appBuild; self.macOSVersion = macOSVersion
        self.hardwareModel = hardwareModel; self.displayCount = displayCount; self.desktopCount = desktopCount
        self.stageManager = stageManager; self.rearrangeSpaces = rearrangeSpaces
        self.accessibilityTrusted = accessibilityTrusted
    }

    /// Markdown bullet lines.
    public var lines: [String] {
        func on(_ v: Bool?) -> String { v.map { $0 ? "on" : "off" } ?? "unknown" }
        func num(_ v: Int?) -> String { v.map(String.init) ?? "unknown" }
        return [
            "- App: \(appVersion) (build \(appBuild))",
            "- macOS: \(macOSVersion)",
            "- Hardware: \(hardwareModel)",
            "- Displays: \(num(displayCount))",
            "- Desktops: \(num(desktopCount))",
            "- Stage Manager: \(on(stageManager))",
            "- Automatically rearrange Spaces: \(on(rearrangeSpaces))",
            "- Accessibility: \(accessibilityTrusted.map { $0 ? "trusted" : "NOT trusted" } ?? "unknown")",
        ]
    }
}

public struct BugReportInput: Sendable {
    public var title: String
    public var description: String
    public var expected: String
    public var steps: String
    public var environment: BugReportEnvironment
    public var includeLogs: Bool
    public var logLines: [String]
    public var debugRunSummary: String?
    public var restoreSummary: String?

    public init(title: String = "", description: String = "", expected: String = "", steps: String = "",
                environment: BugReportEnvironment = BugReportEnvironment(), includeLogs: Bool = true,
                logLines: [String] = [], debugRunSummary: String? = nil, restoreSummary: String? = nil) {
        self.title = title; self.description = description; self.expected = expected; self.steps = steps
        self.environment = environment; self.includeLogs = includeLogs; self.logLines = logLines
        self.debugRunSummary = debugRunSummary; self.restoreSummary = restoreSummary
    }
}

public enum BugReport {
    public static let repo = "alisinaee/windows-manager"
    public static let maxLogLines = 300
    public static let maxURLBodyLength = 6000
    public static let shortLogLines = 60

    /// Last `count` lines of a text.
    public static func tail(_ text: String, count: Int = maxLogLines) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return Array(lines.suffix(count))
    }

    public static var logFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Windows Manager", isDirectory: true)
    }

    /// Markdown issue body, already redacted. `compact` keeps only the Environment and the last 60 log lines.
    public static func body(_ input: BugReportInput, redactor: BugRedactor, compact: Bool = false) -> String {
        func clean(_ s: String, _ fallback: String) -> String {
            let t = redactor.redact(s.trimmingCharacters(in: .whitespacesAndNewlines))
            return t.isEmpty ? fallback : t
        }
        var out: [String] = []
        if !compact {
            out += ["### What happened", "", clean(input.description, "_Describe what went wrong._"), ""]
            out += ["### Expected", "", clean(input.expected, "_What did you expect to happen?_"), ""]
            out += ["### Steps", "", clean(input.steps, "1. \n2. \n3. "), ""]
        }
        out += ["### Environment", ""] + input.environment.lines.map { redactor.redact($0) } + [""]
        if let r = input.restoreSummary, !compact {
            out += ["Last restore: " + redactor.redact(r), ""]
        }
        if input.includeLogs {
            var lines = input.logLines
            if compact { lines = Array(lines.suffix(shortLogLines)) }
            var text = lines.map { redactor.redact($0) }.joined(separator: "\n")
            if let d = input.debugRunSummary, !compact { text += (text.isEmpty ? "" : "\n\n") + "--- debug-run ---\n" + redactor.redact(d) }
            if text.isEmpty { text = "(no log lines found)" }
            out += ["### Logs", "", "<details>", "<summary>Logs (redacted)</summary>", "", "```", text.replacingOccurrences(of: "```", with: "'''"), "```", "", "</details>", ""]
        }
        if compact { out += ["_Logs are shortened here. The full redacted logs are in the zip bundle; please attach it._", ""] }
        return out.joined(separator: "\n")
    }

    public struct IssueLink: Sendable, Equatable {
        public var url: URL
        public var truncated: Bool
    }

    /// Prefilled new-issue URL. A body over ~6000 characters (percent-encoded count) falls back to the compact body.
    public static func issueLink(_ input: BugReportInput, redactor: BugRedactor) -> IssueLink {
        let title = redactor.redact(input.title.isEmpty ? "Bug report" : input.title)
        var body = Self.body(input, redactor: redactor)
        var truncated = false
        if encode(body).count > maxURLBodyLength {
            body = Self.body(input, redactor: redactor, compact: true)
            truncated = true
        }
        let s = "https://github.com/\(repo)/issues/new?template=bug_report.yml&title=\(encode(title))&body=\(encode(body))"
        return IssueLink(url: URL(string: s)!, truncated: truncated)
    }

    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    public static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
