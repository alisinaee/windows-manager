import Foundation

/// Machine-readable description of the `wm` CLI, built from the Registry (`wm schema --json`).
public enum CLISchema {
    public static let schemaVersion = 1

    /// Exit codes with their stable names and meanings.
    public static let exitCodes: [(code: CLIExitCode, name: String, meaning: String)] = [
        (.ok, "ok", "Success"),
        (.runtime, "runtime", "Runtime failure, or an unexpected error"),
        (.usage, "usage", "Bad arguments or options; fix the call and retry"),
        (.notFound, "not_found", "Profile, layout, rule or window id not found"),
        (.permission, "permission", "A macOS permission is missing (Accessibility); see wm doctor"),
        (.appNotRunning, "app_not_running", "The call needs the running app (--via app) and it is not running"),
        (.partial, "partial", "Partial result: some windows were unmatched (verify, run)"),
    ]

    public static func exitCodeJSON() -> JSONValue {
        .array(exitCodes.map {
            .object(["code": .int(Int($0.code.rawValue)), "name": .string($0.name), "meaning": .string($0.meaning)])
        })
    }

    /// Shape of every reply. Success: `{"ok":true,"data":...}`; failure: `{"ok":false,"error":{...}}`.
    public static func envelopeJSON() -> JSONValue {
        .object([
            "success": .object(["ok": .bool(true), "data": .string("command-specific JSON value")]),
            "failure": .object([
                "ok": .bool(false),
                "error": .object([
                    "code": .string("stable machine code, e.g. usage, not_found, runtime"),
                    "message": .string("human readable"),
                    "hint": .string("optional next step"),
                ]),
            ]),
            "ndjson": .string("Long runs (wm run --json) print one object per line with an \"event\" field, then the envelope"),
        ])
    }

    /// Full schema document: global flags, exit codes, envelope and every command (sorted by name).
    public static func document(version: String, commands: [Command]) -> JSONValue {
        .object([
            "schemaVersion": .int(schemaVersion),
            "tool": .string("wm"),
            "version": .string(version),
            "globalFlags": .array(Registry.globalOptions.map { o in
                .object(["name": .string("--" + o.name),
                         "short": o.short.map { .string("-\($0)") } ?? .null,
                         "summary": .string(o.summary),
                         "takesValue": .bool(o.takesValue)])
            }),
            "exitCodes": exitCodeJSON(),
            "envelope": envelopeJSON(),
            "commands": .array(commands.sorted { $0.name < $1.name }.map { $0.descriptor }),
        ])
    }
}
