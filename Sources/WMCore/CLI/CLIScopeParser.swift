import Foundation

// Parses the repeatable `--monitor`, `--desktop` and `--app` flags of `wm run` and `wm plan` into a RestoreScope
// resolved against one profile. Pure: it reads the profile only, so it is unit-tested without a live desktop.

public enum CLIScopeParser {
    /// The three scope flags, shared by `wm run` and `wm plan`.
    public static let options: [CLIOption] = [
        CLIOption("monitor", "Limit to a monitor by uuid, name part or 1-based index (repeatable)",
                  takesValue: true, valueName: "monitor"),
        CLIOption("desktop", "Limit to Desktop N; with --monitor, of that monitor only (repeatable)",
                  takesValue: true, valueName: "N"),
        CLIOption("app", "Limit to an app by bundle id or name part (repeatable)",
                  takesValue: true, valueName: "bundle|name"),
    ]

    /// The scope the flags name, or `.whole` when none is given.
    public static func scope(from args: ParsedArgs, profile: Profile) throws -> RestoreScope {
        try parse(profile: profile, monitors: args.values("monitor"), desktops: args.values("desktop"),
                  apps: args.values("app"))
    }

    /// Resolves raw flag values against `profile`. Throws a usage error (exit 2) when a value matches nothing, is
    /// ambiguous, or the resulting scope selects nothing; the hint lists the profile's monitors, Desktops and apps.
    public static func parse(profile: Profile, monitors: [String] = [], desktops: [String] = [],
                             apps: [String] = []) throws -> RestoreScope {
        if monitors.isEmpty && desktops.isEmpty && apps.isEmpty { return .whole }
        let displays: Set<String>? = try monitors.isEmpty ? nil : resolveMonitors(monitors, in: profile)
        let numbers = try desktops.map(parseDesktopNumber)
        let refs: Set<SpaceRef>? = try numbers.isEmpty ? nil : resolveDesktops(numbers, displays: displays, in: profile)
        let appIDs: Set<String>? = try apps.isEmpty ? nil : resolveApps(apps, in: profile)

        let scope = RestoreScope(displays: displays, desktops: refs, apps: appIDs)
        let result = scope.filter(profile)
        if scope.isEmpty(for: profile) || (result.windows.isEmpty && result.spaces.isEmpty) {
            throw CLIFailure.usage("The scope selects nothing in profile \"\(profile.name)\"", hint: hint(for: profile))
        }
        return scope
    }

    /// Adds `"scope": summary` to a JSON object (report or plan output). Other values are returned unchanged.
    public static func addingScope(_ summary: String, to value: JSONValue) -> JSONValue {
        guard case .object(var fields) = value else { return value }
        fields["scope"] = .string(summary)
        return .object(fields)
    }

    // MARK: Resolution

    /// A monitor by exact uuid (ignoring case), else by 1-based index when the value is digits, else by name part.
    static func resolveMonitors(_ raws: [String], in profile: Profile) throws -> Set<String> {
        var uuids = Set<String>()
        for raw in raws {
            let value = raw.trimmingCharacters(in: .whitespaces)
            let found = monitors(matching: value, in: profile.displays)
            guard let display = found.first, found.count == 1 else {
                let message = found.isEmpty ? "--monitor \(value) matches no monitor in this profile"
                    : "--monitor \(value) matches \(found.count) monitors"
                throw CLIFailure.usage(message, hint: hint(for: profile))
            }
            uuids.insert(display.uuid)
        }
        return uuids
    }

    static func monitors(matching value: String, in displays: [DisplayIdentity]) -> [DisplayIdentity] {
        let lower = value.lowercased()
        guard !lower.isEmpty else { return [] }
        if let exact = displays.first(where: { $0.uuid.lowercased() == lower }) { return [exact] }
        if lower.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(lower) {
            return displays.indices.contains(n - 1) ? [displays[n - 1]] : []
        }
        return displays.filter { $0.name.lowercased().contains(lower) }
    }

    /// Desktop N on the chosen monitors (or on every monitor of the profile when none is chosen). Each number must
    /// exist on at least one targeted monitor.
    static func resolveDesktops(_ numbers: [Int], displays: Set<String>?, in profile: Profile) throws -> Set<SpaceRef> {
        var targets: [String] = []
        for uuid in profile.displays.map(\.uuid) + profile.spaces.map(\.displayUUID) where !targets.contains(uuid) {
            if displays?.contains(uuid) ?? true { targets.append(uuid) }
        }
        var refs = Set<SpaceRef>()
        for number in numbers {
            let hits = targets.filter { uuid in
                profile.spaces.contains { $0.kind == .desktop && $0.displayUUID == uuid && $0.desktopNumber == number }
            }
            guard !hits.isEmpty else {
                let onMonitor = displays == nil ? "" : " on the chosen monitor"
                throw CLIFailure.usage("Desktop \(number) does not exist\(onMonitor) in profile \"\(profile.name)\"",
                                       hint: hint(for: profile))
            }
            for uuid in hits { refs.insert(SpaceRef(displayUUID: uuid, desktopNumber: number)) }
        }
        return refs
    }

    /// An app by exact bundle id (ignoring case), else by case-insensitive name part. Apps without a bundle id
    /// cannot be scoped and are skipped.
    static func resolveApps(_ raws: [String], in profile: Profile) throws -> Set<String> {
        let apps = profile.windows.map(\.app)
        var ids = Set<String>()
        for raw in raws {
            let value = raw.trimmingCharacters(in: .whitespaces)
            let lower = value.lowercased()
            let exact = lower.isEmpty ? [] : apps.filter { $0.bundleID?.lowercased() == lower }
            let matched = exact.isEmpty && !lower.isEmpty ? apps.filter { $0.name.lowercased().contains(lower) } : exact
            let bundles = matched.compactMap(\.bundleID)
            guard !bundles.isEmpty else {
                throw CLIFailure.usage("--app \(value) matches no app in profile \"\(profile.name)\"",
                                       hint: hint(for: profile))
            }
            ids.formUnion(bundles)
        }
        return ids
    }

    static func parseDesktopNumber(_ raw: String) throws -> Int {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard let n = Int(value), n >= 1 else {
            throw CLIFailure.usage("--desktop expects a Desktop number of 1 or more, got '\(value)'",
                                   hint: "Use --desktop 2 for Desktop 2")
        }
        return n
    }

    // MARK: Hints

    /// Lists the profile's monitors, Desktops and apps so a retry can use exact values.
    static func hint(for profile: Profile) -> String {
        func name(_ uuid: String) -> String {
            profile.displays.first { $0.uuid == uuid }?.name ?? uuid
        }
        let monitors = profile.displays.enumerated().map { index, display in
            "\(index + 1) \(display.name) (\(display.uuid))"
        }
        var uuids: [String] = []
        for uuid in profile.displays.map(\.uuid) + profile.spaces.map(\.displayUUID) where !uuids.contains(uuid) {
            uuids.append(uuid)
        }
        let desktops: [String] = uuids.compactMap { uuid in
            let numbers = profile.spaces.filter { $0.kind == .desktop && $0.displayUUID == uuid }
                .compactMap(\.desktopNumber).sorted()
            guard !numbers.isEmpty else { return nil }
            return "\(name(uuid)) \(numbers.map(String.init).joined(separator: ", "))"
        }
        var apps: [String] = []
        for app in profile.windows.map(\.app) where !apps.contains(app.name) { apps.append(app.name) }
        return "Monitors: \(monitors.isEmpty ? "none" : monitors.joined(separator: "; ")). "
            + "Desktops: \(desktops.isEmpty ? "none" : desktops.joined(separator: "; ")). "
            + "Apps: \(apps.isEmpty ? "none" : apps.joined(separator: ", "))."
    }
}
