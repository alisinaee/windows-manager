import Foundation
import WMCore

/// Runs async MainActor work from the synchronous command handler by spinning the main run loop.
func runOnMain<T>(_ body: @escaping @MainActor () async -> T) -> T {
    var result: T?
    Task { @MainActor in
        let value = await body()
        result = value
    }
    while result == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    return result!
}

/// Finds a profile by name or id through ProfileStore.
func loadProfileByQuery(_ query: String) throws -> Profile {
    let store = ProfileStore()
    switch CLIProfileLookup.resolve(query, in: store.list()) {
    case .found(let id):
        do { return try store.load(id) } catch { throw CLIFailure(.runtime, code: "profile_unreadable", message: "\(error.localizedDescription)") }
    case .notFound:
        throw CLIFailure.notFound("No profile named or with id '\(query)'", hint: "List profiles with: wm profile list")
    case .ambiguous(let options):
        throw CLIFailure.usage("'\(query)' matches several profiles: \(options.joined(separator: ", "))", hint: "Use the profile id")
    }
}

func requireAccessibility() throws {
    guard AXPermission.isTrusted() else {
        throw CLIFailure(.permission, code: "accessibility_not_trusted",
                         message: "Accessibility is not granted to this terminal app",
                         hint: "System Settings > Privacy & Security > Accessibility: enable your terminal, then retry (wm doctor --json)")
    }
}

func registerRunCommands(_ r: Registry) {
    r.register(Command(["run"], summary: "Restore a profile (streams NDJSON progress with --json)",
                       args: [CLIArg("profile", "Profile name or id")],
                       options: [CLIOption("dry-run", "Plan only, change nothing"),
                                 CLIOption("yes", short: "y", "Do not ask for confirmation")],
                       mutates: true, touchesWindows: true) { args, ctx in
        let profile = try loadProfileByQuery(args.positionals[0])
        let dry = args.flag("dry-run")
        if !dry { try requireAccessibility() }
        if !dry && !args.flag("yes") && !ctx.json && isatty(0) != 0 {
            FileHandle.standardError.write(Data("Restore \"\(profile.name)\" now? This moves windows. [y/N] ".utf8))
            guard let line = readLine(), line.lowercased().hasPrefix("y") else {
                throw CLIFailure(.runtime, code: "cancelled", message: "Cancelled", hint: "Pass --yes to skip the question")
            }
        }
        let events = ctx.events
        let json = ctx.json
        let report = runOnMain { () -> RestoreReport in
            await RestoreEngine().run(profile, dryRun: dry) { event in
                if json { events.emit("progress", CLIRunEvents.fields(for: event)) }
                else { FileHandle.standardError.write(Data((event.message + "\n").utf8)) }
            }
        }
        return CLIResult(data: try JSONValue.from(report), exit: CLIRunOutcome.exit(for: report), text: report.summary)
    })
}
