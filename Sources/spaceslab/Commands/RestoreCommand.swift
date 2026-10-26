import Foundation
import WMCore

enum RestoreCommand {
    static let name = "restore"
    static let help = "Restore a saved profile onto the live workspace (--profile FILE --dry-run --yes)"

    static let usage = """
        Usage: spaceslab restore --profile FILE [--dry-run] [--yes]

          --profile FILE  A profile JSON as written by `spaceslab capture --out FILE`.
          --dry-run       Scan, match and print the plan; change nothing (this is also the default).
          --yes           Execute the plan: launch missing apps, then exit full screen, unminimize, move to
                          Desktops, place windows, enter full screen, minimize, restack and hide other apps.

        Without --yes nothing is launched, moved, resized, full-screened, minimized, hidden or quit.
        "Other apps: quit" is never executed here; those apps are only listed as needing confirmation.
        Needs Accessibility access to execute. The run is saved as lab-results/restore-*.json.

        """

    static func run(_ args: [String]) -> Int32 {
        var profilePath: String?
        var dryRun = false
        var yes = false

        var index = 0
        while index < args.count {
            switch args[index] {
            case "--dry-run":
                dryRun = true
                index += 1
            case "--yes", "-y":
                yes = true
                index += 1
            case "--profile":
                guard index + 1 < args.count else {
                    fputs("restore: --profile needs a file\n\n" + usage, stderr)
                    return 2
                }
                profilePath = args[index + 1]
                index += 2
            case "-h", "--help":
                print(usage, terminator: "")
                return 0
            default:
                fputs("restore: unknown option \(args[index])\n\n" + usage, stderr)
                return 2
            }
        }
        guard let profilePath else {
            fputs("restore: --profile is required\n\n" + usage, stderr)
            return 2
        }

        let profile: Profile
        do {
            let url = URL(fileURLWithPath: (profilePath as NSString).expandingTildeInPath)
            profile = try ProfileStore.decode(try Data(contentsOf: url), source: profilePath)
        } catch {
            fputs("restore: could not read \(profilePath): \(error.localizedDescription)\n", stderr)
            return 1
        }

        // An explicit --dry-run wins over --yes; without --yes the run is a dry run.
        let execute = yes && !dryRun
        if execute && !AXPermission.isTrusted() {
            fputs("restore: Accessibility permission is missing for this process, so windows cannot be moved (see `spaceslab doctor`)\n", stderr)
            return 1
        }

        print("Profile \"\(profile.name)\": \(profile.displays.count) display(s), \(profile.windows.count) window(s), "
            + "\(profile.apps.count) app(s). Mode: " + (execute ? "EXECUTE" : "dry run (nothing will be changed)"))
        for problem in profile.validate() { print("profile problem: \(problem)") }

        var lab = LabResult(test: "restore")
        lab.observe("profile", "\(profile.name) (\(profilePath))")
        lab.observe("mode", execute ? "execute" : "dry-run")

        var plans = 0
        let report = runOnMain { () -> RestoreReport in
            let engine = RestoreEngine()
            return await engine.run(profile, dryRun: !execute) { event in
                switch event {
                case .planned(let plan):
                    plans += 1
                    print("")
                    print(plans == 1 ? plan.outline : "Plan after launching: \(plan.steps.count) step(s), "
                        + "\(plan.unmatched.count) window(s) not found")
                    print("")
                    lab.step(event.message)
                case .stepStarted:
                    break
                default:
                    print(event.message)
                    lab.step(event.message)
                }
                fflush(stdout)
            }
        }

        print("")
        print("Result: \(report.summary) in \(String(format: "%.1f", report.elapsed)) s")
        if report.dryRun {
            print("Dry run: nothing was changed. Add --yes to restore.")
        }
        if !report.unmatched.isEmpty && !report.dryRun {
            print("Not found (\(report.unmatched.count)):")
            for item in report.unmatched { print("  - \(item.label): \(item.reason)") }
        }
        let failed = report.steps.filter { $0.status.isFailed }
        if !failed.isEmpty {
            print("Failed steps (\(failed.count)):")
            for record in failed { print("  - \(record.description): \(record.status.reason ?? "")") }
        }
        if !report.needsConfirmation.isEmpty {
            print("These apps are set to be quit and need confirmation (nothing was quit): "
                + report.needsConfirmation.map(\.name).joined(separator: ", "))
        }

        lab.observe("summary", report.summary)
        lab.observe("steps", "\(report.totals.steps) (\(report.totals.done) done, \(report.totals.skipped) skipped, \(report.totals.failed) failed)")
        lab.observe("windows", "\(report.totals.windowsPlaced) placed, \(report.totals.windowsPartial) partial, "
            + "\(report.totals.windowsFailed) failed, \(report.totals.windowsNotFound) not found")
        if let data = try? report.jsonData() { lab.observe("report", String(decoding: data, as: UTF8.self)) }
        lab.finish(passed: execute ? report.isClean : nil)
        do {
            let url = try lab.save()
            print("Saved \(url.path)")
        } catch {
            fputs("restore: could not save the lab result: \(error.localizedDescription)\n", stderr)
            return 1
        }
        return execute && !report.isClean ? 1 : 0
    }

    // MARK: Running the async engine from a synchronous command

    private final class Box<Value>: @unchecked Sendable {
        var value: Value?
    }

    /// Runs `body` on the main actor and keeps the main run loop going until it is done (the engine and the
    /// SkyLight calls it makes need the main thread and its run loop).
    private static func runOnMain<T: Sendable>(_ body: @escaping @MainActor () async -> T) -> T {
        let box = Box<T>()
        Task { @MainActor in box.value = await body() }
        while box.value == nil {
            if !RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return box.value!
    }
}
