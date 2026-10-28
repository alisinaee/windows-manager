import Foundation
import WMCore

func registerPlanCommands(_ r: Registry) {
    r.register(Command(["plan"], summary: "Dry-run plan for a profile, grouped by phase (changes nothing)",
                       args: [CLIArg("profile", "Profile name or id")]) { args, _ in
        let profile = try loadProfileByQuery(args.positionals[0])
        let plan = runOnMain { await RestoreEngine().preview(profile: profile) }
        let result = CLIPlanResult(profileID: profile.id, plan: plan)
        return CLIResult(data: try JSONValue.from(result), exit: result.exit, text: plan.outline)
    })
}
