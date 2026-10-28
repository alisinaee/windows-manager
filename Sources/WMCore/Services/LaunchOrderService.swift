import Foundation

// Headless launch-order editing (the Studio "Launch order" tab). Items are addressed by an item ref: the
// `LaunchItem.id` (lowercased bundle id, or "name:<app>"), the app name, or a 1-based position.
// Setting anything on a profile that has no plan first builds one from its apps, in parallel mode, exactly like
// the Studio, so nothing changes until an edit says so.

public struct LaunchOrderView: Equatable, Sendable {
    public var profileID: UUID
    public var plan: LaunchPlan
    /// True when the profile has no saved plan (the plan shown is the implicit parallel one).
    public var isImplicit: Bool
    /// The steps the restore engine will perform, in order.
    public var requests: [ProfileLaunchRequest]
    public var issues: [LaunchIssue]
    public var worstCaseSeconds: TimeInterval
}

public struct LaunchOrderService {
    public let profiles: ProfileService

    public init(store: ProfileStore = ProfileStore()) {
        self.profiles = ProfileService(store: store)
    }

    public init(profiles: ProfileService) { self.profiles = profiles }

    /// The effective plan: the saved one (or an implicit parallel one) with unlisted apps appended.
    public static func effectivePlan(_ profile: Profile) -> LaunchPlan {
        var plan = profile.launchPlan ?? LaunchPlan(mode: .parallel)
        for app in profile.launchApps {
            let item = LaunchItem(app: app)
            if !plan.items.contains(where: { $0.id == item.id }) { plan.items.append(item) }
        }
        return plan
    }

    public func get(_ ref: String, installedApps: Set<String>? = nil) throws -> LaunchOrderView {
        let p = try profiles.show(ref)
        let plan = Self.effectivePlan(p)
        return LaunchOrderView(profileID: p.id, plan: plan, isImplicit: p.launchPlan == nil,
                               requests: LaunchSequence.order(p),
                               issues: LaunchSequence.validate(plan: plan, profile: p, installedApps: installedApps),
                               worstCaseSeconds: LaunchSequence.worstCaseDuration(plan: plan))
    }

    // MARK: Plan-level edits

    public func setMode(_ ref: String, mode: LaunchPlan.Mode) throws -> Profile {
        try change(ref) { $0.mode = mode }
    }

    /// Replaces the whole plan (for import/scripting).
    public func setPlan(_ ref: String, plan: LaunchPlan) throws -> Profile {
        try profiles.edit(ref) { try $0.setLaunchPlan(plan) }
    }

    /// Removes the saved plan: every app launches in parallel again.
    public func reset(_ ref: String) throws -> Profile {
        try profiles.edit(ref) { try $0.setLaunchPlan(nil) }
    }

    /// Replaces the order with `items` (item refs, first to last). Unlisted items keep their relative order after.
    public func setOrder(_ ref: String, items refs: [String]) throws -> Profile {
        try change(ref) { plan in
            var rest = plan.items
            var ordered: [LaunchItem] = []
            for r in refs {
                let i = try Self.index(of: r, in: rest)
                ordered.append(rest.remove(at: i))
            }
            plan.items = ordered + rest
        }
    }

    /// Moves an item to a 1-based position.
    public func move(_ ref: String, item: String, toPosition position: Int) throws -> Profile {
        try change(ref) { plan in
            let from = try Self.index(of: item, in: plan.items)
            plan = LaunchSequence.moved(plan, from: from, to: position - 1)
        }
    }

    // MARK: Item edits

    public func setEnabled(_ ref: String, item: String, enabled: Bool) throws -> Profile {
        try edit(ref, item) { $0.enabled = enabled }
    }

    /// Seconds to wait after the app before the next one (0...60, clamped). Only used in sequential mode.
    public func setDelay(_ ref: String, item: String, seconds: TimeInterval) throws -> Profile {
        guard seconds.isFinite, seconds >= 0 else { throw ServiceError.invalid("A delay must be 0 or more seconds.") }
        return try edit(ref, item) { $0.delayAfter = seconds }
    }

    /// Seconds to wait for the app (5...120, clamped); nil restores the default.
    public func setTimeout(_ ref: String, item: String, seconds: TimeInterval?) throws -> Profile {
        if let seconds, !(seconds.isFinite && seconds > 0) { throw ServiceError.invalid("A timeout must be a positive number of seconds.") }
        return try edit(ref, item) { $0.timeout = seconds }
    }

    public func setWait(_ ref: String, item: String, wait: LaunchWait) throws -> Profile {
        try edit(ref, item) { $0.wait = wait }
    }

    public func setActivates(_ ref: String, item: String, activates: Bool) throws -> Profile {
        try edit(ref, item) { $0.activates = activates }
    }

    public func setWithoutWindows(_ ref: String, item: String, launchOnly: Bool) throws -> Profile {
        try edit(ref, item) {
            $0.withoutWindows = launchOnly
            if launchOnly { $0.wait = .appReady }
        }
    }

    /// Adds an app to the launch order (launch-only unless `withWindows`). Duplicate apps are a conflict.
    public func addApp(_ ref: String, app: AppRef, launchOnly: Bool = true, position: Int? = nil) throws -> Profile {
        try change(ref) { plan in
            let item = LaunchItem(app: app, wait: launchOnly ? .appReady : LaunchItem.defaultWait, withoutWindows: launchOnly)
            guard !plan.items.contains(where: { $0.id == item.id }) else {
                throw ServiceError.conflict("\(app.name) is already in the launch order.")
            }
            plan.items.append(item)
            if let position { plan = LaunchSequence.moved(plan, from: plan.items.count - 1, to: position - 1) }
        }
    }

    public func removeApp(_ ref: String, item: String) throws -> Profile {
        try change(ref) { plan in plan.items.remove(at: try Self.index(of: item, in: plan.items)) }
    }

    // MARK: Plumbing

    private func change(_ ref: String, _ body: (inout LaunchPlan) throws -> Void) throws -> Profile {
        let p = try profiles.show(ref)
        var plan = Self.effectivePlan(p)
        try body(&plan)
        return try profiles.edit(ref) { try $0.setLaunchPlan(plan) }
    }

    private func edit(_ ref: String, _ item: String, _ body: (inout LaunchItem) -> Void) throws -> Profile {
        try change(ref) { plan in
            let i = try Self.index(of: item, in: plan.items)
            body(&plan.items[i])
        }
    }

    static func index(of ref: String, in items: [LaunchItem]) throws -> Int {
        let q = ref.trimmingCharacters(in: .whitespaces).lowercased()
        if let i = items.firstIndex(where: { $0.id == q }) { return i }
        if let i = items.firstIndex(where: { $0.app.name.lowercased() == q }) { return i }
        if let n = Int(q), items.indices.contains(n - 1) { return n - 1 }
        throw ServiceError.notFound("No launch item \"\(ref)\".")
    }
}
