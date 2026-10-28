import Foundation

// Scoped restore (P6.115/P6.117): limits a restore to some monitors, Desktops or apps. A nil set means "all".
// `filter` is pure; the engine runs the filtered profile and leaves everything outside the scope untouched.

/// One Desktop of one display: the display UUID plus the 1-based "Desktop N" number.
public struct SpaceRef: Hashable, Codable, Sendable {
    public var displayUUID: String
    public var desktopNumber: Int

    public init(displayUUID: String, desktopNumber: Int) {
        self.displayUUID = displayUUID
        self.desktopNumber = desktopNumber
    }
}

public enum ScopeError: Error, Equatable, Sendable {
    /// The scope matches nothing in the profile.
    case emptyScope
}

extension ScopeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyScope: return "The chosen scope matches nothing in this profile."
        }
    }
}

public struct RestoreScope: Codable, Equatable, Sendable {
    /// `DisplayIdentity.uuid` values; nil = every monitor.
    public var displays: Set<String>?
    /// Desktops (display + number); nil = every Desktop. Full-screen Spaces are outside a Desktop scope.
    public var desktops: Set<SpaceRef>?
    /// Bundle ids (compared ignoring case); nil = every app.
    public var apps: Set<String>?

    public init(displays: Set<String>? = nil, desktops: Set<SpaceRef>? = nil, apps: Set<String>? = nil) {
        self.displays = displays
        self.desktops = desktops
        self.apps = apps
    }

    public static let whole = RestoreScope()

    public var isWhole: Bool { displays == nil && desktops == nil && apps == nil }

    /// True when the scope selects nothing of `profile`.
    public func isEmpty(for profile: Profile) -> Bool {
        let result = filter(profile)
        if result.windows.isEmpty { return apps != nil || result.spaces.isEmpty }
        // All-Desktops windows alone do not make a Desktop scope non-empty: the Desktop must exist.
        if desktops != nil {
            return result.spaces.isEmpty && !result.windows.contains { if case .desktop = $0.placement { return true } else { return false } }
        }
        return false
    }

    /// Whether a display is inside the monitor and Desktop parts of the scope.
    public func includes(display uuid: String) -> Bool {
        if let displays, !displays.contains(uuid) { return false }
        if let desktops, !desktops.contains(where: { $0.displayUUID == uuid }) { return false }
        return true
    }

    /// Whether something on `display` matches. `desktop` is the 1-based Desktop number, nil for an all-Desktops
    /// window (matches when its display is in scope). `bundleID` nil = no app (a Space), matches the app part only
    /// when apps are not scoped.
    public func matches(display: String, desktop: Int?, bundleID: String?) -> Bool {
        guard includes(display: display) else { return false }
        if let desktops, let desktop, !desktops.contains(SpaceRef(displayUUID: display, desktopNumber: desktop)) {
            return false
        }
        if let apps {
            guard let bundleID, apps.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) else {
                return false
            }
        }
        return true
    }

    private func matches(_ window: WindowSnapshot) -> Bool {
        let desktop: Int?
        switch window.placement {
        case .desktop(let number): desktop = number
        case .allDesktops: desktop = nil
        case .fullScreen, .unknown:
            if desktops != nil { return false }
            desktop = nil
        }
        return matches(display: window.displayUUID, desktop: desktop, bundleID: window.app.bundleID)
    }

    /// The profile reduced to the scope. Windows and Spaces outside it are dropped; positions and Desktop numbers
    /// are NOT renumbered, so the result still names the real Desktops. A whole scope returns `profile` unchanged.
    public func filter(_ profile: Profile) -> Profile {
        if isWhole { return profile }
        var result = profile
        result.windows = profile.windows.filter(matches)
        let kept = Set(result.windows.map(\.id))

        var spaces: [SpaceSnapshot] = []
        for var space in profile.spaces {
            guard includes(display: space.displayUUID), displays?.contains(space.displayUUID) ?? true else { continue }
            if space.kind == .fullScreen {
                guard desktops == nil else { continue }
                let owners = space.fullScreenWindowIDs.filter(kept.contains)
                guard !owners.isEmpty else { continue }
                space.fullScreenWindowIDs = owners
            } else if let desktops {
                guard space.kind == .desktop, let number = space.desktopNumber,
                      desktops.contains(SpaceRef(displayUUID: space.displayUUID, desktopNumber: number)) else { continue }
            }
            spaces.append(space)
        }
        result.spaces = spaces

        let used = Set(result.windows.map(\.displayUUID)).union(spaces.map(\.displayUUID))
        result.displays = profile.displays.filter { used.contains($0.uuid) }

        if var plan = profile.launchPlan {
            let remaining = result.apps
            plan.items = plan.items.filter { item in
                !item.withoutWindows && remaining.contains { Profile.isSameApp($0, item.app) }
            }
            result.launchPlan = plan
        }
        return result
    }

    /// A short sentence for reports and chips, e.g. "Desktop 2 on DELL only" or "Whole profile".
    public func describe(profile: Profile) -> String {
        if isWhole { return "Whole profile" }
        func monitorName(_ uuid: String) -> String {
            profile.displays.first { $0.uuid == uuid }?.name ?? uuid
        }
        var parts: [String] = []
        if let desktops {
            let sorted = desktops.sorted { ($0.displayUUID, $0.desktopNumber) < ($1.displayUUID, $1.desktopNumber) }
            let multi = Set(sorted.map(\.displayUUID)).count > 1
            var byDisplay: [(String, [Int])] = []
            for ref in sorted {
                if let i = byDisplay.firstIndex(where: { $0.0 == ref.displayUUID }) {
                    byDisplay[i].1.append(ref.desktopNumber)
                } else {
                    byDisplay.append((ref.displayUUID, [ref.desktopNumber]))
                }
            }
            let text = byDisplay.map { uuid, numbers in
                let label = (numbers.count == 1 ? "Desktop " : "Desktops ") + numbers.map(String.init).joined(separator: ", ")
                return (multi || displays != nil || profile.displays.count > 1) ? "\(label) on \(monitorName(uuid))" : label
            }.joined(separator: "; ")
            parts.append(text)
        } else if let displays {
            let names = displays.map(monitorName).sorted()
            parts.append((names.count == 1 ? "Monitor " : "Monitors ") + names.joined(separator: ", "))
        }
        if let apps {
            let names = apps.map { id in
                profile.windows.first { $0.app.bundleID?.caseInsensitiveCompare(id) == .orderedSame }?.app.name ?? id
            }.sorted()
            parts.append("only " + names.joined(separator: ", "))
        }
        return parts.joined(separator: ", ") + (apps == nil ? " only" : "")
    }
}
