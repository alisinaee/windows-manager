import Foundation
import WMCore

func registerPlanCommands(_ r: Registry) {
    r.register(Command(["plan"], summary: "Dry-run plan for a profile, grouped by phase (changes nothing)",
                       args: [CLIArg("profile", "Profile name or id")],
                       options: CLIScopeParser.options) { args, _ in
        let profile = try loadProfileByQuery(args.positionals[0])
        let scope = try CLIScopeParser.scope(from: args, profile: profile)
        let plan = runOnMain { await RestoreEngine().preview(profile: profile, scope: scope) }
        let result = CLIPlanResult(profileID: profile.id, plan: plan)
        let data = CLIScopeParser.addingScope(scope.describe(profile: profile), to: try JSONValue.from(result))
        return CLIResult(data: data, exit: result.exit, text: plan.outline)
    })
}
