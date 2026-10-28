import Foundation

// Pure helpers behind the system commands (doctor, settings, layouts, rules, debug, spaces). Unit tested in
// Tests/WMCoreTests/CLISystemCommandsTests.swift. Nothing here touches windows.

/// Maps service errors to CLI failures: notFound -> 3, invalid -> 2, conflict and failed -> 1.
public enum CLIServiceErrorMapping {
    public static func exit(for error: ServiceError) -> CLIExitCode {
        switch error {
        case .notFound: return .notFound
        case .invalid: return .usage
        case .conflict, .failed: return .runtime
        }
    }

    /// Any error a service throws becomes the failure the envelope reports.
    public static func failure(_ error: Error) -> CLIFailure {
        if let failure = error as? CLIFailure { return failure }
        let service = ServiceError.wrap(error)
        return CLIFailure(exit(for: service), code: service.code, message: service.message)
    }
}

/// Runs a service call and rethrows its error as a `CLIFailure`.
public func cliService<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch {
        throw CLIServiceErrorMapping.failure(error)
    }
}

/// One line of `wm doctor`.
public struct DoctorItem: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var ok: Bool
    public var detail: String
    public var fix: String?

    public init(id: String, title: String, ok: Bool, detail: String, fix: String?) {
        self.id = id
        self.title = title
        self.ok = ok
        self.detail = detail
        self.fix = fix
    }
}

public enum DoctorReport {
    /// Exit 4 (permission missing) when Accessibility is not trusted; everything else is informational.
    public static func exit(_ items: [DoctorItem]) -> CLIExitCode {
        guard let access = items.first(where: { $0.id == "accessibility" }) else { return .ok }
        return access.ok ? .ok : .permission
    }

    public static func text(_ items: [DoctorItem]) -> String {
        items.map { item in
            var line = "\(item.ok ? "ok  " : "FAIL") \(item.title): \(item.detail)"
            if !item.ok, let fix = item.fix { line += "\n      fix: \(fix)" }
            return line
        }.joined(separator: "\n")
    }
}

/// Settings values as JSON and as one text line.
public enum CLISettingFormat {
    public static func json(_ value: SettingValue) -> JSONValue {
        switch value {
        case .bool(let v): return .bool(v)
        case .int(let v): return .int(v)
        case .double(let v): return .double(v)
        case .string(let v): return .string(v)
        }
    }

    public static func entry(_ entry: SettingEntry) -> JSONValue {
        .object([
            "key": .string(entry.key),
            "value": json(entry.value),
            "default": json(entry.defaultValue),
            "isDefault": .bool(entry.isDefault),
            "kind": .string(entry.kind),
            "summary": .string(entry.summary),
        ])
    }

    public static func line(_ entry: SettingEntry) -> String {
        "\(entry.key) = \(entry.value)" + (entry.isDefault ? "" : "  (default \(entry.defaultValue))")
    }
}
