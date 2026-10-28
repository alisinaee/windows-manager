import Foundation
import WMCore

func registerVerifyCommands(_ r: Registry) {
    r.register(Command(["verify"], summary: "Compare live windows with a profile (exit 6 on mismatch)",
                       args: [CLIArg("profile", "Profile name or id")]) { args, _ in
        let profile = try loadProfileByQuery(args.positionals[0])
        let plan = runOnMain { await RestoreEngine().preview(profile: profile) }
        let result = CLIVerifyResult(profile: profile, plan: plan)
        var text = "\(profile.name): \(result.mismatches) mismatch(es) of \(result.checked) window(s)"
        for w in result.windows where !w.passed {
            text += "\n  \(w.status): \(w.app)\(w.title.map { " \"\($0)\"" } ?? "")" + (w.detail.map { " - \($0)" } ?? "")
        }
        return CLIResult(data: try JSONValue.from(result), exit: result.exit, text: text)
    })
}
