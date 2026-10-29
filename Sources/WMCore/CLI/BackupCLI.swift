import Foundation

// `wm backup create|list|restore`: the Space order backups the Space guard makes (SpaceBindingsBackup).
// Restore changes system preferences and restarts the Dock, so it needs an explicit --yes.

public enum BackupCommands {
    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    static func entry(_ b: BackupInfo) -> JSONValue {
        .object(["id": .string(b.id), "path": .string(b.url.path), "date": .string(iso(b.date)), "reason": .string(b.reason)])
    }

    static func fail(_ error: Error) -> CLIFailure {
        guard let e = error as? SpaceBindingsBackupError else { return CLIServiceErrorMapping.failure(error) }
        let hint: String? = e == .notConfirmed ? "Add --yes to restore." : nil
        return CLIFailure(e == .notConfirmed ? .usage : .runtime, code: "backup", message: e.localizedDescription, hint: hint)
    }

    /// A backup by file name (id), unique file-name prefix, or "latest".
    static func resolve(_ ref: String, in all: [BackupInfo]) throws -> BackupInfo {
        if ref == "latest", let first = all.first { return first }
        if let hit = all.first(where: { $0.id == ref }) { return hit }
        let prefixed = all.filter { $0.id.hasPrefix(ref) }
        if prefixed.count == 1 { return prefixed[0] }
        if prefixed.count > 1 { throw CLIFailure.usage("\"\(ref)\" matches \(prefixed.count) backups; give the full id.", hint: "Run: wm backup list") }
        throw CLIFailure.notFound("No backup \"\(ref)\".", hint: "Run: wm backup list")
    }

    public static func register(_ r: Registry, backup: @escaping () -> SpaceBindingsBackup) {
        r.register(Command(["backup", "list"], summary: "List Space order backups, newest first") { _, _ in
            let all = backup().list()
            return CLIResult(data: .object(["backups": .array(all.map(entry))]),
                             text: all.isEmpty ? "No backups." : all.map { "\($0.id)\t\(iso($0.date))\t\($0.reason)" }.joined(separator: "\n"))
        })
        r.register(Command(["backup", "create"], summary: "Back up the Space order and Mission Control shortcuts now (read-only on the system)",
                           options: [CLIOption("reason", "Short label stored in the file name (default: manual)", takesValue: true, valueName: "text")],
                           mutates: true) { a, _ in
            do {
                let info = try backup().backupNow(reason: a.value("reason") ?? "manual")
                return CLIResult(data: entry(info), text: info.url.path)
            } catch { throw fail(error) }
        })
        r.register(Command(["backup", "restore"], summary: "Restore a Space order backup (changes system preferences, restarts the Dock; needs --yes)",
                           args: [CLIArg("backup", "File name, unique prefix, or latest")],
                           options: [CLIOption("yes", "Confirm the restore"),
                                     CLIOption("no-dock-restart", "Import the preferences but do not restart the Dock")],
                           mutates: true) { a, _ in
            let service = backup()
            let info = try resolve(a.positionals[0], in: service.list())
            guard a.flag("yes") else {
                throw CLIFailure.usage("Restoring \(info.id) changes system Space preferences and restarts the Dock.", hint: "Add --yes to restore.")
            }
            do { try service.restore(info, confirmed: true, killDock: !a.flag("no-dock-restart")) } catch { throw fail(error) }
            return CLIResult(data: .object(["restored": entry(info), "dockRestarted": .bool(!a.flag("no-dock-restart"))]),
                             text: "restored \(info.id)")
        })
    }
}
