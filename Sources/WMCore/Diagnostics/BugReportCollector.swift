import AppKit
import ApplicationServices
import Foundation

/// Reads the live machine state for a bug report and writes the zip bundle. Not unit tested (touches the system).
public enum BugReportCollector {
    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func defaultsBool(_ domain: String, _ key: String) -> Bool? {
        run("/usr/bin/defaults", ["read", domain, key]).flatMap(parseDefaultsBool)
    }

    /// `infoDictionary` is the app's Info.plist (nil for the CLI, which reports "wm").
    public static func environment(info: [String: Any]?) -> BugReportEnvironment {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return BugReportEnvironment(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info?["CFBundleVersion"] as? String ?? "unknown",
            macOSVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            hardwareModel: run("/usr/sbin/sysctl", ["-n", "hw.model"]) ?? "unknown",
            displayCount: NSScreen.screens.count,
            desktopCount: nil,
            stageManager: defaultsBool("com.apple.WindowManager", "GloLevelEnabled") ?? false,
            rearrangeSpaces: defaultsBool("com.apple.dock", "mru-spaces") ?? true,
            accessibilityTrusted: AXIsProcessTrusted())
    }

    public static func readLogTail(folder: URL = BugReport.logFolder) -> [String] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("debug.log")) else { return [] }
        return BugReport.tail(String(decoding: data, as: UTF8.self))
    }

    public static func readDebugRunSummary(folder: URL = BugReport.logFolder) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("debug-run.json")) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return String(text.prefix(4000))
    }

    /// Gathers everything with the logs read from disk.
    public static func input(title: String, description: String, expected: String = "", steps: String = "",
                             includeLogs: Bool, info: [String: Any]?) -> BugReportInput {
        BugReportInput(title: title, description: description, expected: expected, steps: steps,
                       environment: environment(info: info), includeLogs: includeLogs,
                       logLines: includeLogs ? readLogTail() : [],
                       debugRunSummary: includeLogs ? readDebugRunSummary() : nil)
    }

    public enum BundleError: Error, LocalizedError {
        case zipFailed
        public var errorDescription: String? { "Could not create the zip file." }
    }

    /// Writes `WindowsManager-BugReport-<timestamp>.zip` into `directory`: report.md, redacted logs, optional profile JSON.
    public static func writeBundle(_ input: BugReportInput, redactor: BugRedactor = .current, profileJSON: Data? = nil,
                                   directory: URL, date: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let name = "WindowsManager-BugReport-\(BugReport.timestamp(date))"
        let staging = fm.temporaryDirectory.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try BugReport.body(input, redactor: redactor).write(to: staging.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        if input.includeLogs {
            let log = input.logLines.map { redactor.redact($0) }.joined(separator: "\n")
            try log.write(to: staging.appendingPathComponent("debug.log"), atomically: true, encoding: .utf8)
            if let d = input.debugRunSummary {
                try redactor.redact(d).write(to: staging.appendingPathComponent("debug-run.json"), atomically: true, encoding: .utf8)
            }
        }
        if let profileJSON {
            let text = redactor.redact(String(decoding: profileJSON, as: UTF8.self))
            try text.write(to: staging.appendingPathComponent("profile.json"), atomically: true, encoding: .utf8)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let zip = directory.appendingPathComponent(name + ".zip")
        try? fm.removeItem(at: zip)
        guard run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, zip.path]) != nil else { throw BundleError.zipFailed }
        return zip
    }

    public static var desktopFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
    }
}
