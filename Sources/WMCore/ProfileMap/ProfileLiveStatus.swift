import Foundation

// Live status for the Profile Map (phase PM3): what a restore would do with each saved window and each saved
// Desktop, read straight from the `RestorePlan` the planner made. Nothing here compares frames or Spaces on its
// own, so the map can never disagree with what Run does. Pure: no system calls.
//
// Per saved window (`WindowSnapshot`, in profile order):
//  - `restore == false`                  -> notRestored (the planner never looks at it)
//  - in `plan.unmatched`, app launches   -> willLaunch (a `.launch` step for its app is in the plan)
//  - in `plan.unmatched`, otherwise      -> notFound(reason:), the planner's own reason
//  - in `plan.possiblyParked`            -> no entry in `windows`; listed in `parked` (Stage Manager may hold it)
//  - a step targets it, other than raise -> willMove (placed, resized, moved to a Desktop, minimized, full screen)
//  - otherwise                           -> inPlace. Restacking alone (`raise`) is not a move.
//
// Per saved Desktop: each `plan.missingDesktops` entry becomes `desktopMissing` on the saved monitor of its
// windows; `willBeAdded` is true when the plan has an `addDesktop` step on that monitor that covers the number.

/// What a restore would do with one saved window.
public enum WindowLiveStatus: Equatable, Sendable {
    /// Matched, and the plan leaves it alone.
    case inPlace
    /// Matched, and the plan moves, resizes, changes its Desktop or changes its minimized or full-screen state.
    case willMove
    /// No live window now, but the plan launches its app and the window is expected to open.
    case willLaunch
    /// No live window and nothing will launch it. `reason` is the planner's text, for people.
    case notFound(reason: String)
    /// The profile has this window's restore switched off.
    case notRestored
}

/// A saved Desktop: "Desktop N" of a saved monitor, keyed by the monitor's saved uuid.
public struct SpaceKey: Hashable, Sendable {
    /// `DisplayIdentity.uuid` of the saved monitor (as in `Profile.displays`).
    public var displayUUID: String
    /// 1-based "Desktop N".
    public var desktopNumber: Int

    public init(displayUUID: String, desktopNumber: Int) {
        self.displayUUID = displayUUID
        self.desktopNumber = desktopNumber
    }
}

/// What a restore would do with one saved Desktop.
public enum SpaceLiveStatus: Equatable, Sendable {
    /// The profile needs this Desktop, the monitor has fewer, and the plan does not add it. The windows listed
    /// stay where they are. `available` is how many Desktops the monitor has now.
    case desktopMissing(available: Int, willBeAdded: Bool, snapshotIDs: [UUID])
}

/// Counts for the summary line above the map. Window counts add up to the number of saved windows.
public struct ProfileLiveSummary: Equatable, Sendable {
    public var inPlace: Int
    public var willMove: Int
    /// Windows that will open because their app is launched.
    public var willLaunch: Int
    /// Distinct apps the plan launches.
    public var appsToLaunch: Int
    public var notFound: Int
    public var notRestored: Int
    /// Saved Desktops the monitors do not have.
    public var missingDesktops: Int
    /// Windows that may sit in the Stage Manager strip or another stage (neither found nor missing).
    public var mayBeParked: Int

    public init(inPlace: Int = 0, willMove: Int = 0, willLaunch: Int = 0, appsToLaunch: Int = 0, notFound: Int = 0,
                notRestored: Int = 0, missingDesktops: Int = 0, mayBeParked: Int = 0) {
        self.inPlace = inPlace
        self.willMove = willMove
        self.willLaunch = willLaunch
        self.appsToLaunch = appsToLaunch
        self.notFound = notFound
        self.notRestored = notRestored
        self.missingDesktops = missingDesktops
        self.mayBeParked = mayBeParked
    }

    /// Saved windows counted above.
    public var windowCount: Int { inPlace + willMove + willLaunch + notFound + notRestored + mayBeParked }
}

/// The status of a profile against the present, as the plan of a restore sees it.
public struct ProfileLiveStatus: Equatable, Sendable {
    /// Per saved window, by `WindowSnapshot.id`. Every window of the profile has an entry, except those in `parked`.
    public var windows: [UUID: WindowLiveStatus]
    /// Saved windows the plan could not match but that may be in the Stage Manager strip (neutral: not a
    /// problem, not a move). They have no entry in `windows`.
    public var parked: Set<UUID>
    /// Per saved Desktop that is missing now. Desktops that exist have no entry.
    public var spaces: [SpaceKey: SpaceLiveStatus]
    public var summary: ProfileLiveSummary

    /// Projects `plan` (made by `RestorePlanner.plan` or `RestoreEngine.preview` for `profile`) onto the profile.
    public init(profile: Profile, plan: RestorePlan) {
        // Steps that move a window, and the apps the plan launches.
        var movingIDs = Set<UUID>()
        var launchApps: [AppRef] = []
        var addedDesktops: [(displayUUID: String, count: Int)] = []
        for step in plan.steps {
            switch step {
            case .launch(let app, _):
                launchApps.append(app)
            case .addDesktop(let display, let count):
                addedDesktops.append((display.uuid, count))
            case .raise:
                break
            default:
                if let target = step.target { movingIDs.insert(target.snapshotID) }
            }
        }

        let unmatched = Dictionary(plan.unmatched.map { ($0.snapshotID, $0) }, uniquingKeysWith: { first, _ in first })
        var windows: [UUID: WindowLiveStatus] = [:]
        var parked = Set<UUID>()
        let possiblyParked = Set(plan.possiblyParked)
        for snapshot in profile.windows where windows[snapshot.id] == nil {
            if !snapshot.restore {
                windows[snapshot.id] = .notRestored
            } else if let missing = unmatched[snapshot.id] {
                if launchApps.contains(where: { Profile.isSameApp($0, missing.app) }) {
                    windows[snapshot.id] = .willLaunch
                } else {
                    windows[snapshot.id] = .notFound(reason: missing.reason)
                }
            } else if possiblyParked.contains(snapshot.id) {
                parked.insert(snapshot.id)
            } else {
                windows[snapshot.id] = movingIDs.contains(snapshot.id) ? .willMove : .inPlace
            }
        }

        // Missing Desktops: one entry per saved monitor and Desktop number.
        var spaces: [SpaceKey: SpaceLiveStatus] = [:]
        for missing in plan.missingDesktops {
            let willBeAdded = addedDesktops.contains { added in
                added.displayUUID.caseInsensitiveCompare(missing.displayUUID) == .orderedSame
                    && missing.number <= missing.available + added.count
            }
            let owners = profile.windows.filter { missing.snapshotIDs.contains($0.id) }
            for (displayUUID, group) in Dictionary(grouping: owners, by: \.displayUUID) {
                let key = SpaceKey(displayUUID: displayUUID, desktopNumber: missing.number)
                spaces[key] = .desktopMissing(available: missing.available, willBeAdded: willBeAdded,
                                              snapshotIDs: group.map(\.id))
            }
        }

        var summary = ProfileLiveSummary(appsToLaunch: launchApps.count, missingDesktops: spaces.count)
        for status in windows.values {
            switch status {
            case .inPlace: summary.inPlace += 1
            case .willMove: summary.willMove += 1
            case .willLaunch: summary.willLaunch += 1
            case .notFound: summary.notFound += 1
            case .notRestored: summary.notRestored += 1
            }
        }

        summary.mayBeParked = parked.count
        self.windows = windows
        self.parked = parked
        self.spaces = spaces
        self.summary = summary
    }
}
