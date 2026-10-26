import Foundation

// Launch order logic for the Profile Studio "Launch order" tab (phase PM5). Pure: no system calls, no UI.
//
// `order` is what the restore engine (EN1) walks: enabled items in plan order, then the apps of the profile
// that the plan does not list, in the profile's captured order. Disabled items are never launched, and apps
// they name are not launched through the default order either.
//
// A profile without a launch plan launches every app in parallel, as before, so `order` treats nil as a
// parallel plan with no items.
//
// Editing helpers return a new plan. Delay and timeout clamping lives in `LaunchItem`, so every edit keeps it.

/// One launch step the engine performs, in order.
public struct ProfileLaunchRequest: Equatable, Sendable {
    public var app: AppRef
    /// Windows to wait for: the restorable window snapshots of this app. 0 for appReady, launch-only and
    /// withoutWindows.
    public var minWindows: Int
    /// Seconds to wait for the app or its windows; nil means `LaunchOptions.defaultTimeout`.
    public var timeout: TimeInterval?
    /// Seconds to wait after this step before the next one. The engine uses it only in sequential mode.
    public var delayAfter: TimeInterval
    /// Mode of the plan the request belongs to.
    public var mode: LaunchPlan.Mode
    /// When this step counts as finished.
    public var wait: LaunchWait

    public init(app: AppRef, minWindows: Int, timeout: TimeInterval?, delayAfter: TimeInterval,
                mode: LaunchPlan.Mode, wait: LaunchWait) {
        self.app = app
        self.minWindows = minWindows
        self.timeout = timeout
        self.delayAfter = delayAfter
        self.mode = mode
        self.wait = wait
    }
}

/// A problem with a launch order, with a sentence to show next to the item.
public struct LaunchIssue: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// The same app is listed twice.
        case duplicateApp
        /// The app's bundle id is not among the installed apps.
        case notInstalled
        /// A delay is set, but the plan runs in parallel, so the delay does nothing.
        case delayIgnoredInParallel
        /// The timeout ends before the delay after the app does.
        case timeoutShorterThanDelay
        /// The app has no windows in the profile and is not launch-only, so its wait can never end by windows.
        case noWindowsNotLaunchOnly
    }

    public var kind: Kind
    /// `LaunchItem.id` of the item the issue is about.
    public var itemID: String
    /// Readable sentence for people.
    public var message: String

    public init(kind: Kind, itemID: String, message: String) {
        self.kind = kind
        self.itemID = itemID
        self.message = message
    }
}

/// Launch order rules: the request list, validation, worst-case duration and the editor's edits.
public enum LaunchSequence {

    // MARK: Order

    /// The steps the engine performs for a profile, in order.
    public static func order(_ profile: Profile) -> [ProfileLaunchRequest] {
        let plan = profile.launchPlan ?? LaunchPlan(mode: .parallel)
        var requests: [ProfileLaunchRequest] = []
        var launched: [AppRef] = []

        for item in plan.items where item.enabled {
            // The first enabled entry of an app decides its step. Later duplicates are reported by `validate`.
            guard !launched.contains(where: { Profile.isSameApp($0, item.app) }) else { continue }
            launched.append(item.app)
            requests.append(ProfileLaunchRequest(
                app: item.app,
                minWindows: minWindows(for: item, in: profile),
                timeout: item.timeout,
                delayAfter: item.delayAfter,
                mode: plan.mode,
                wait: item.wait))
        }

        // Apps the plan does not mention (enabled or disabled) follow in profile order.
        for app in profile.launchApps
        where !plan.items.contains(where: { Profile.isSameApp($0.app, app) })
            && !launched.contains(where: { Profile.isSameApp($0, app) }) {
            launched.append(app)
            requests.append(ProfileLaunchRequest(
                app: app,
                minWindows: restorableWindowCount(of: app, in: profile),
                timeout: nil,
                delayAfter: 0,
                mode: plan.mode,
                wait: LaunchItem.defaultWait))
        }
        return requests
    }

    private static func minWindows(for item: LaunchItem, in profile: Profile) -> Int {
        guard item.wait == .windows, !item.withoutWindows else { return 0 }
        return restorableWindowCount(of: item.app, in: profile)
    }

    private static func restorableWindowCount(of app: AppRef, in profile: Profile) -> Int {
        profile.windows(for: app).filter(\.restore).count
    }

    // MARK: Validation

    /// Everything wrong with a launch plan for a profile. Empty means the plan is consistent.
    /// `installedApps` holds bundle ids (any case). Pass nil to skip the installed check. Apps without a bundle
    /// id cannot be checked against that set and are skipped.
    public static func validate(plan: LaunchPlan, profile: Profile, installedApps: Set<String>? = nil) -> [LaunchIssue] {
        let installed = installedApps.map { Set($0.map { $0.lowercased() }) }
        var issues: [LaunchIssue] = []
        var seen: [AppRef] = []

        for item in plan.items {
            let name = item.app.name
            let id = item.id

            if seen.contains(where: { Profile.isSameApp($0, item.app) }) {
                issues.append(LaunchIssue(kind: .duplicateApp, itemID: id,
                    message: "\(name) is listed more than once in the launch order. Remove one of the entries."))
            } else {
                seen.append(item.app)
            }

            if let installed, let bundleID = item.app.bundleID?.lowercased(), !bundleID.isEmpty,
               !installed.contains(bundleID) {
                issues.append(LaunchIssue(kind: .notInstalled, itemID: id,
                    message: "\(name) is not installed (no app with bundle id \(bundleID) was found). "
                        + "Install it or remove it from the launch order."))
            }

            if plan.mode == .parallel, item.delayAfter > 0 {
                issues.append(LaunchIssue(kind: .delayIgnoredInParallel, itemID: id,
                    message: "\(name) has a delay after it, but the launch order runs in parallel, so the delay is ignored. "
                        + "Choose one app after another to use delays."))
            }

            if let timeout = item.timeout, timeout < item.delayAfter {
                issues.append(LaunchIssue(kind: .timeoutShorterThanDelay, itemID: id,
                    message: "\(name) times out after \(format(timeout)) s, before its \(format(item.delayAfter)) s delay "
                        + "ends. Raise the timeout or shorten the delay."))
            }

            if item.enabled, !item.withoutWindows, profile.windows(for: item.app).isEmpty {
                issues.append(LaunchIssue(kind: .noWindowsNotLaunchOnly, itemID: id,
                    message: "\(name) has no windows in this profile and is not marked launch only, so its launch "
                        + "would wait for windows that never appear. Mark it launch only or add a window."))
            }
        }
        return issues
    }

    private static func format(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }

    // MARK: Duration

    /// The longest the enabled items of a plan can take. Sequential: each item's timeout plus its delay, added up.
    /// Parallel: the longest timeout, since the apps wait together and delays are ignored.
    /// An item without a timeout uses `LaunchOptions.defaultTimeout`. Apps the plan does not list are not counted.
    public static func worstCaseDuration(plan: LaunchPlan) -> TimeInterval {
        let enabled = plan.items.filter(\.enabled)
        switch plan.mode {
        case .sequential:
            return enabled.reduce(0) { $0 + ($1.timeout ?? LaunchOptions.defaultTimeout) + $1.delayAfter }
        case .parallel:
            return enabled.map { $0.timeout ?? LaunchOptions.defaultTimeout }.max() ?? 0
        }
    }

    // MARK: Editing

    /// Moves the item at `source` so it ends up at index `destination` of the result. Indices outside the list
    /// are clamped, and a `source` outside the list returns the plan unchanged.
    public static func moved(_ plan: LaunchPlan, from source: Int, to destination: Int) -> LaunchPlan {
        guard plan.items.indices.contains(source) else { return plan }
        var result = plan
        let item = result.items.remove(at: source)
        result.items.insert(item, at: min(max(destination, 0), result.items.count))
        return result
    }

    /// Flips `enabled` for the items with this id.
    public static func toggled(_ plan: LaunchPlan, id: String) -> LaunchPlan {
        var result = plan
        for index in result.items.indices where result.items[index].id == id {
            result.items[index].enabled.toggle()
        }
        return result
    }

    /// Sets the delay after the items with this id. Clamped to `LaunchItem.delayRange`.
    public static func settingDelay(_ plan: LaunchPlan, id: String, _ seconds: TimeInterval) -> LaunchPlan {
        var result = plan
        for index in result.items.indices where result.items[index].id == id {
            result.items[index].delayAfter = seconds
        }
        return result
    }

    /// Sets the timeout of the items with this id. Clamped to `LaunchItem.timeoutRange`; nil keeps the default.
    public static func settingTimeout(_ plan: LaunchPlan, id: String, _ seconds: TimeInterval?) -> LaunchPlan {
        var result = plan
        for index in result.items.indices where result.items[index].id == id {
            result.items[index].timeout = seconds
        }
        return result
    }

    /// Sets what the items with this id wait for.
    public static func settingWait(_ plan: LaunchPlan, id: String, _ wait: LaunchWait) -> LaunchPlan {
        var result = plan
        for index in result.items.indices where result.items[index].id == id {
            result.items[index].wait = wait
        }
        return result
    }
}
