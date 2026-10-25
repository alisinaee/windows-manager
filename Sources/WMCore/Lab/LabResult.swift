import Foundation

/// One timed log line inside a lab run.
public struct LabStep: Codable, Equatable {
    /// Seconds since the run started.
    public var offset: TimeInterval
    public var message: String

    public init(offset: TimeInterval, message: String) {
        self.offset = offset
        self.message = message
    }
}

/// The record of one `spaceslab` experiment. Saved as JSON under ./lab-results/.
public struct LabResult: Codable {
    public var test: String
    public var started: Date
    public var finished: Date?
    public var macOS: String
    /// nil = not decided (observations only).
    public var passed: Bool?
    public var steps: [LabStep]
    public var observations: [String: String]

    public init(test: String, started: Date = Date()) {
        self.test = test
        self.started = started
        self.finished = nil
        self.macOS = ProcessInfo.processInfo.operatingSystemVersionString
        self.passed = nil
        self.steps = []
        self.observations = [:]
    }

    /// Adds a log line stamped with the time since the run started.
    public mutating func step(_ message: String) {
        steps.append(LabStep(offset: Date().timeIntervalSince(started), message: message))
    }

    /// Records a named fact (overwrites an earlier value with the same name).
    public mutating func observe(_ key: String, _ value: String) {
        observations[key] = value
    }

    /// Marks the run as finished now, optionally setting the verdict.
    public mutating func finish(passed: Bool? = nil) {
        finished = Date()
        if let passed { self.passed = passed }
    }

    /// ./lab-results in the current directory.
    public static var defaultFolder: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("lab-results")
    }

    /// Writes pretty JSON to ./lab-results/<test>-<yyyyMMdd-HHmmss>.json and returns the file URL.
    public func save() throws -> URL {
        try save(in: LabResult.defaultFolder)
    }

    /// Same as `save()` but into a chosen folder (created if needed).
    public func save(in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = LabResult.fileStamp.string(from: started)
        var url = folder.appendingPathComponent("\(test)-\(stamp).json")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(test)-\(stamp)-\(counter).json")
            counter += 1
        }
        try LabResult.encoder().encode(self).write(to: url, options: .atomic)
        return url
    }

    /// Reads one saved result.
    public static func load(from url: URL) throws -> LabResult {
        try decoder().decode(LabResult.self, from: Data(contentsOf: url))
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var fileStamp: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }
}

/// Turns a folder of saved lab results into one markdown summary.
public enum LabReport {
    public static func markdown(from folder: URL) throws -> String {
        var loaded: [(file: String, result: LabResult)] = []
        var broken: [String] = []

        if FileManager.default.fileExists(atPath: folder.path) {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                do {
                    loaded.append((file.lastPathComponent, try LabResult.load(from: file)))
                } catch {
                    broken.append(file.lastPathComponent)
                }
            }
        }
        loaded.sort { ($0.result.started, $0.file) < ($1.result.started, $1.file) }

        var out = "# Spaces Lab report\n\n"
        if loaded.isEmpty && broken.isEmpty {
            out += "_No lab results found in \(folder.path)._\n"
            return out
        }

        out += "| Test | Started (UTC) | Duration | macOS | Result | Steps |\n"
        out += "|---|---|---|---|---|---|\n"
        for (_, r) in loaded {
            let duration = r.finished.map { String(format: "%.1fs", $0.timeIntervalSince(r.started)) } ?? "-"
            out += "| \(cell(r.test)) | \(isoString(r.started)) | \(duration) | \(cell(r.macOS)) | \(verdict(r.passed)) | \(r.steps.count) |\n"
        }

        for (file, r) in loaded {
            out += "\n## \(r.test)\n\n"
            out += "File: `\(file)`  \nResult: \(verdict(r.passed))\n\n"
            if r.observations.isEmpty {
                out += "_No observations._\n"
            } else {
                out += "Observations:\n\n"
                for key in r.observations.keys.sorted() {
                    out += "- `\(key)`: \(r.observations[key] ?? "")\n"
                }
            }
        }

        if !broken.isEmpty {
            out += "\n## Unreadable files\n\n"
            for name in broken { out += "- `\(name)`\n" }
        }
        return out
    }

    private static func verdict(_ passed: Bool?) -> String {
        switch passed {
        case .some(true): return "PASS"
        case .some(false): return "FAIL"
        case .none: return "n/a"
        }
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
