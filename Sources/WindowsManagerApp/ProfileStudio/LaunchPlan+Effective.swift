import WMCore

extension LaunchPlan {
    /// The plan the Launch page shows: the profile's plan followed by apps of the profile it does not list (they
    /// launch last, in profile order). No plan at all means "parallel", as the engine reads it.
    static func effective(for profile: Profile) -> LaunchPlan {
        var plan = profile.launchPlan ?? LaunchPlan(mode: .parallel)
        for app in profile.launchApps {
            let item = LaunchItem(app: app)
            if !plan.items.contains(where: { $0.id == item.id }) { plan.items.append(item) }
        }
        return plan
    }
}
