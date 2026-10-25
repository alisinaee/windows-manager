import Foundation

// Reads and rewrites the Space order macOS keeps in the com.apple.spaces preference domain.
//
// Two places hold an order, and this file always changes both together:
//   Monitors                 (SpacesDisplayConfiguration > Management Data > Monitors): one entry per display,
//                            "Spaces" is the list of Space dictionaries in Mission Control order.
//   ManagedSpaceOrdering     (... > Management Data > SpaceAssignments): one entry per display,
//                            "ManagedSpaceIDs" is the list of Space uuids in order ("" = the first Desktop).
// Both can hold stale data (old displays, Spaces that moved away). Every function that writes refuses when the
// layout is not exactly what it understands, because a wrong write can damage the user's Desktop layout.

// MARK: - Model

/// One Space as stored in a Monitors entry.
public struct StoredSpace: Equatable {
    /// Space uuid. "" is the first Desktop of the main display.
    public var uuid: String
    /// "id64" / "ManagedSpaceID"; nil when the entry has neither.
    public var id: UInt64?
    /// 0 = Desktop, 4 = full-screen, anything else is not understood.
    public var type: Int?
    /// App name of a full-screen Space (TileLayoutManager > TileSpaces > appName).
    public var ownerName: String?

    public init(uuid: String, id: UInt64? = nil, type: Int? = nil, ownerName: String? = nil) {
        self.uuid = uuid
        self.id = id
        self.type = type
        self.ownerName = ownerName
    }

    public var isDesktop: Bool { type == 0 }
    public var isFullScreen: Bool { type == 4 }
}

/// The stored order of one display: its Monitors entry plus the ManagedSpaceOrdering entry that belongs to it.
public struct StoredDisplayOrder: Equatable {
    /// "Display Identifier" of the Monitors entry: "Main" or a display UUID.
    public var displayIdentifier: String
    /// Index of the entry inside the Monitors array.
    public var monitorIndex: Int
    /// Monitors > Spaces, in order.
    public var spaces: [StoredSpace]
    /// Index of the matching entry inside the ManagedSpaceOrdering array; nil when none was found (or it was ambiguous).
    public var orderingIndex: Int?
    /// "ManagedDisplayID" of that entry. For "Main" this is usually the real display UUID, not "Main".
    public var orderingDisplayID: String?
    /// Its "ManagedSpaceIDs" as stored; may contain stale uuids that are not Spaces of this display.
    public var orderingUUIDs: [String]?
    /// Why no ManagedSpaceOrdering entry was matched, or how it was matched when not by identifier.
    public var orderingNote: String?
    /// Things in the Monitors entry that were not understood (a Space without a uuid, duplicate uuids).
    public var problems: [String]

    public init(displayIdentifier: String, monitorIndex: Int, spaces: [StoredSpace], orderingIndex: Int? = nil,
                orderingDisplayID: String? = nil, orderingUUIDs: [String]? = nil, orderingNote: String? = nil,
                problems: [String] = []) {
        self.displayIdentifier = displayIdentifier
        self.monitorIndex = monitorIndex
        self.spaces = spaces
        self.orderingIndex = orderingIndex
        self.orderingDisplayID = orderingDisplayID
        self.orderingUUIDs = orderingUUIDs
        self.orderingNote = orderingNote
        self.problems = problems
    }

    /// Space uuids in Monitors order.
    public var monitorUUIDs: [String] { spaces.map(\.uuid) }

    /// The ordering entry without its stale uuids, so it can be compared with `monitorUUIDs`.
    public var orderingLiveUUIDs: [String]? {
        guard let orderingUUIDs else { return nil }
        let own = Set(monitorUUIDs)
        return orderingUUIDs.filter { own.contains($0) }
    }

    /// Uuids the ordering entry holds that are not Spaces of this display's Monitors entry.
    public var staleOrderingUUIDs: [String] {
        guard let orderingUUIDs else { return [] }
        let own = Set(monitorUUIDs)
        return orderingUUIDs.filter { !own.contains($0) }
    }

    /// True when the ordering entry lists this display's Spaces in the same order as Monitors. Nil without an entry.
    public var isConsistent: Bool? {
        orderingLiveUUIDs.map { $0 == monitorUUIDs }
    }
}

/// Where in the config the two arrays were found, and why a layout was rejected.
public struct StoredLayout: Equatable {
    /// Key path from the config root to the Monitors array; nil when not found.
    public var monitorsPath: [String]?
    /// Key path from the config root to the ManagedSpaceOrdering array; nil when not found.
    public var orderingPath: [String]?
    /// Reasons this layout cannot be written safely (missing array, array found in several places, ...).
    public var problems: [String]

    public init(monitorsPath: [String]? = nil, orderingPath: [String]? = nil, problems: [String] = []) {
        self.monitorsPath = monitorsPath
        self.orderingPath = orderingPath
        self.problems = problems
    }

    /// Both arrays were found exactly once and nothing looked wrong.
    public var isUsable: Bool { monitorsPath != nil && orderingPath != nil && problems.isEmpty }

    public var summary: String {
        let monitors = monitorsPath?.joined(separator: " > ") ?? "not found"
        let ordering = orderingPath?.joined(separator: " > ") ?? "not found"
        return "Monitors: \(monitors); ManagedSpaceOrdering: \(ordering)"
    }
}

/// Everything `parseStoredOrder` finds, plus the facts `order-file show` prints.
public struct StoredInspection: Equatable {
    public var layout: StoredLayout
    /// Displays whose Monitors entry has Spaces, in Monitors array order.
    public var displays: [StoredDisplayOrder]
    /// Size of the Monitors array.
    public var monitorEntryCount: Int
    /// Monitors entries without Spaces (displays that are gone).
    public var staleMonitorCount: Int
}

public enum SpaceOrderFileError: Error, LocalizedError, Equatable {
    case domainUnreadable(String)
    case unexpectedShape(String)
    case displayNotFound(String)
    case ambiguousDisplay(String)
    case orderingNotMatched(String)
    case spaceSetMismatch(String)
    case writeFailed(String)
    case commandFailed(String)
    case backupFailed(String)
    case dockDidNotRestart(String)

    public var errorDescription: String? {
        switch self {
        case .domainUnreadable(let detail): return "com.apple.spaces could not be read: \(detail)"
        case .unexpectedShape(let detail): return "The stored layout is not one this tool understands (refusing to write): \(detail)"
        case .displayNotFound(let id): return "No stored display with Spaces has the identifier \(id)"
        case .ambiguousDisplay(let detail): return "Display is ambiguous (refusing to write): \(detail)"
        case .orderingNotMatched(let detail): return "No single ManagedSpaceOrdering entry belongs to this display (refusing to write): \(detail)"
        case .spaceSetMismatch(let detail): return "The set of Spaces would change (refusing to write): \(detail)"
        case .writeFailed(let detail): return "Writing the preferences failed: \(detail)"
        case .commandFailed(let detail): return detail
        case .backupFailed(let detail): return "Backup failed: \(detail)"
        case .dockDidNotRestart(let detail): return detail
        }
    }
}

/// What `restartDock` observed.
public struct DockRestartResult: Equatable {
    public var oldPID: Int32?
    public var newPID: Int32
    /// Seconds until a new Dock process existed.
    public var secondsUntilDock: TimeInterval
    /// Seconds until SpaceReader answered again, counted from the kill.
    public var secondsUntilSpaces: TimeInterval
}

// MARK: - SpaceOrderFile

public enum SpaceOrderFile {
    public static let domain = "com.apple.spaces"
    static let rootKey = "SpacesDisplayConfiguration"

    /// Key paths (below SpacesDisplayConfiguration, or below the config itself when it is passed without that
    /// key) where each array is known to live. A layout is rejected when an array shows up in none of them or
    /// in more than one, so a moved key stops the tool instead of letting it guess.
    static let monitorsPaths: [[String]] = [
        ["Management Data", "Monitors"],
        ["Monitors"],
    ]
    static let orderingPaths: [[String]] = [
        ["Management Data", "SpaceAssignments", "ManagedSpaceOrdering"],
        ["SpaceAssignments", "ManagedSpaceOrdering"],
        ["Management Data", "ManagedSpaceOrdering"],
        ["ManagedSpaceOrdering"],
    ]

    // MARK: Parsing (pure)

    /// The stored order of every display that has Spaces. Empty when the layout is not understood.
    public static func parseStoredOrder(_ config: [String: Any]) -> [StoredDisplayOrder] {
        let inspection = inspect(config)
        return inspection.layout.monitorsPath == nil ? [] : inspection.displays
    }

    /// Like `parseStoredOrder`, with the layout and counts. Never throws; problems end up in `layout.problems`
    /// and in each display's `problems`.
    public static func inspect(_ config: [String: Any]) -> StoredInspection {
        let layout = locate(config)
        guard let monitorsPath = layout.monitorsPath,
              let monitors = value(at: monitorsPath, in: config) as? [Any] else {
            return StoredInspection(layout: layout, displays: [], monitorEntryCount: 0, staleMonitorCount: 0)
        }
        var ordering: [OrderingEntry] = []
        if let orderingPath = layout.orderingPath, let array = value(at: orderingPath, in: config) as? [Any] {
            ordering = parseOrdering(array)
        }

        var displays: [StoredDisplayOrder] = []
        var stale = 0
        for (index, item) in monitors.enumerated() {
            guard let monitor = item as? [String: Any],
                  let rawSpaces = monitor["Spaces"] as? [Any], !rawSpaces.isEmpty else {
                stale += 1
                continue
            }
            let identifier = (monitor["Display Identifier"] as? String) ?? "Main"
            var problems: [String] = []
            var spaces: [StoredSpace] = []
            for (n, raw) in rawSpaces.enumerated() {
                guard let dict = raw as? [String: Any], let uuid = dict["uuid"] as? String else {
                    problems.append("Space \(n + 1) of the Monitors entry has no uuid")
                    continue
                }
                spaces.append(storedSpace(dict, uuid: uuid))
            }
            let uuids = spaces.map(\.uuid)
            if Set(uuids).count != uuids.count { problems.append("the Monitors entry lists a Space uuid twice") }

            var display = StoredDisplayOrder(displayIdentifier: identifier, monitorIndex: index, spaces: spaces,
                                             problems: problems)
            if problems.isEmpty && layout.orderingPath != nil {
                let match = matchOrdering(displayIdentifier: identifier, uuids: uuids, entries: ordering)
                if let entry = match.entry {
                    display.orderingIndex = entry.index
                    display.orderingDisplayID = entry.displayID
                    display.orderingUUIDs = entry.uuids
                }
                display.orderingNote = match.note
            }
            displays.append(display)
        }
        return StoredInspection(layout: layout, displays: displays, monitorEntryCount: monitors.count,
                                staleMonitorCount: stale)
    }

    private static func storedSpace(_ dict: [String: Any], uuid: String) -> StoredSpace {
        let id = ((dict["id64"] ?? dict["ManagedSpaceID"]) as? NSNumber).flatMap { $0.int64Value >= 0 ? UInt64($0.int64Value) : nil }
        let type = (dict["type"] as? NSNumber)?.intValue
        var owner: String?
        let tiles = ((dict["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [Any]) ?? []
        for tile in tiles {
            if let name = (tile as? [String: Any])?["appName"] as? String, !name.isEmpty {
                owner = name
                break
            }
        }
        return StoredSpace(uuid: uuid, id: id, type: type, ownerName: owner)
    }

    // MARK: Layout detection

    private static func locate(_ config: [String: Any]) -> StoredLayout {
        var layout = StoredLayout()
        let base = config[rootKey] is [String: Any] ? [rootKey] : []
        if base.isEmpty && config["Management Data"] == nil && config["Monitors"] == nil {
            layout.problems.append("no \(rootKey) dictionary")
            return layout
        }

        let monitors = monitorsPaths.map { base + $0 }.filter { value(at: $0, in: config) is [Any] }
        switch monitors.count {
        case 0: layout.problems.append("no Monitors array found")
        case 1: layout.monitorsPath = monitors[0]
        default: layout.problems.append("Monitors array found in several places")
        }

        let ordering = orderingPaths.map { base + $0 }.filter { value(at: $0, in: config) is [Any] }
        switch ordering.count {
        case 0: layout.problems.append("no ManagedSpaceOrdering array found")
        case 1: layout.orderingPath = ordering[0]
        default: layout.problems.append("ManagedSpaceOrdering array found in several places")
        }
        return layout
    }

    private static func value(at path: [String], in root: [String: Any]) -> Any? {
        var current: Any = root
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    /// A copy of `dict` with `newValue` stored at `path`. Nil when an intermediate key is not a dictionary.
    private static func setting(_ newValue: Any, at path: ArraySlice<String>, in dict: [String: Any]) -> [String: Any]? {
        guard let key = path.first else { return nil }
        var copy = dict
        if path.count == 1 {
            copy[key] = newValue
            return copy
        }
        guard let child = dict[key] as? [String: Any],
              let updated = setting(newValue, at: path.dropFirst(), in: child) else { return nil }
        copy[key] = updated
        return copy
    }

    // MARK: ManagedSpaceOrdering matching

    private struct OrderingEntry {
        var index: Int
        var displayID: String
        var uuids: [String]
    }

    private static func parseOrdering(_ array: [Any]) -> [OrderingEntry] {
        var entries: [OrderingEntry] = []
        for (index, item) in array.enumerated() {
            guard let dict = item as? [String: Any],
                  let id = dict["ManagedDisplayID"] as? String,
                  let uuids = dict["ManagedSpaceIDs"] as? [String] else { continue }
            entries.append(OrderingEntry(index: index, displayID: id, uuids: uuids))
        }
        return entries
    }

    /// Finds the one ordering entry that belongs to a display. An entry qualifies when it lists every Space of
    /// the display exactly once (it may hold stale extras). Among those, the entry with the same display
    /// identifier wins; otherwise the one with the fewest extras, if that is unique. "Main" needs the second rule
    /// because macOS stores its order under the real display UUID and leaves a stale "Main" entry behind.
    private static func matchOrdering(displayIdentifier: String, uuids: [String],
                                      entries: [OrderingEntry]) -> (entry: OrderingEntry?, note: String?) {
        let wanted = Set(uuids)
        let candidates = entries.filter { entry in
            wanted.isSubset(of: entry.uuids) && entry.uuids.filter { wanted.contains($0) }.count == wanted.count
        }
        if candidates.isEmpty {
            return (nil, "no ManagedSpaceOrdering entry lists all \(wanted.count) Space(s) of this display")
        }
        let same = candidates.filter { $0.displayID.caseInsensitiveCompare(displayIdentifier) == .orderedSame }
        if same.count == 1 { return (same[0], nil) }
        if same.count > 1 {
            return (nil, "\(same.count) ManagedSpaceOrdering entries have the display identifier \(displayIdentifier)")
        }
        let fewest = candidates.map { $0.uuids.count }.min() ?? 0
        let best = candidates.filter { $0.uuids.count == fewest }
        if best.count == 1 {
            return (best[0], "matched by its Space list, not by display identifier")
        }
        return (nil, "\(best.count) ManagedSpaceOrdering entries fit this display equally well "
                + "(\(best.map(\.displayID).joined(separator: ", ")))")
    }

    // MARK: Reordering (pure)

    /// A copy of `config` where the display `displayID` has its Spaces in the order `newOrderUUIDs`, in both the
    /// Monitors entry and the matching ManagedSpaceOrdering entry. Stale uuids in the ordering entry keep their
    /// slots; only the slots of this display's own Spaces are refilled. Throws, and changes nothing, when the
    /// layout is not understood, the display or its ordering entry is not unique, or `newOrderUUIDs` is not a
    /// permutation of the display's current Spaces.
    public static func reordered(_ config: [String: Any], displayID: String,
                                 newOrderUUIDs: [String]) throws -> [String: Any] {
        let inspection = inspect(config)
        let layout = inspection.layout
        guard layout.isUsable, let monitorsPath = layout.monitorsPath, let orderingPath = layout.orderingPath else {
            throw SpaceOrderFileError.unexpectedShape(layout.problems.joined(separator: "; "))
        }

        let matches = inspection.displays.filter { $0.displayIdentifier.caseInsensitiveCompare(displayID) == .orderedSame }
        guard !matches.isEmpty else { throw SpaceOrderFileError.displayNotFound(displayID) }
        guard matches.count == 1, let display = matches.first else {
            throw SpaceOrderFileError.ambiguousDisplay("\(matches.count) Monitors entries with Spaces have the identifier \(displayID)")
        }
        guard display.problems.isEmpty else {
            throw SpaceOrderFileError.unexpectedShape(display.problems.joined(separator: "; "))
        }
        guard let orderingIndex = display.orderingIndex else {
            throw SpaceOrderFileError.orderingNotMatched(display.orderingNote ?? "no entry found")
        }

        // The new order must be exactly the display's current Spaces, each once.
        let current = display.monitorUUIDs
        if newOrderUUIDs.count != current.count || Set(newOrderUUIDs).count != newOrderUUIDs.count
            || Set(newOrderUUIDs) != Set(current) {
            let missing = Set(current).subtracting(newOrderUUIDs).sorted()
            let extra = Set(newOrderUUIDs).subtracting(current).sorted()
            var parts = ["display has \(current.count) Space(s), new order has \(newOrderUUIDs.count)"]
            if !missing.isEmpty { parts.append("missing: \(describe(missing))") }
            if !extra.isEmpty { parts.append("unknown: \(describe(extra))") }
            if Set(newOrderUUIDs).count != newOrderUUIDs.count { parts.append("a uuid is listed twice") }
            throw SpaceOrderFileError.spaceSetMismatch(parts.joined(separator: "; "))
        }

        guard let monitors = value(at: monitorsPath, in: config) as? [Any],
              display.monitorIndex < monitors.count,
              var monitor = monitors[display.monitorIndex] as? [String: Any],
              let spaceItems = monitor["Spaces"] as? [Any],
              let ordering = value(at: orderingPath, in: config) as? [Any],
              orderingIndex < ordering.count,
              var entry = ordering[orderingIndex] as? [String: Any],
              let entryIDs = entry["ManagedSpaceIDs"] as? [Any] else {
            throw SpaceOrderFileError.unexpectedShape("the arrays changed shape while reading them")
        }

        // Monitors > Spaces: the original dictionaries, reordered.
        var byUUID: [String: Any] = [:]
        for item in spaceItems {
            guard let uuid = (item as? [String: Any])?["uuid"] as? String else {
                throw SpaceOrderFileError.unexpectedShape("a Space in the Monitors entry has no uuid")
            }
            byUUID[uuid] = item
        }
        var newSpaces: [Any] = []
        for uuid in newOrderUUIDs {
            guard let item = byUUID[uuid] else {
                throw SpaceOrderFileError.spaceSetMismatch("Space \(describe([uuid])) is not in the Monitors entry")
            }
            newSpaces.append(item)
        }
        monitor["Spaces"] = newSpaces

        // ManagedSpaceOrdering: refill only the slots that hold this display's own Spaces.
        let own = Set(current)
        var refill = newOrderUUIDs.makeIterator()
        var newIDs: [Any] = []
        for item in entryIDs {
            if let uuid = item as? String, own.contains(uuid) {
                guard let next = refill.next() else {
                    throw SpaceOrderFileError.spaceSetMismatch("ordering entry has more of this display's Spaces than the Monitors entry")
                }
                newIDs.append(next)
            } else {
                newIDs.append(item)
            }
        }
        guard refill.next() == nil else {
            throw SpaceOrderFileError.spaceSetMismatch("ordering entry has fewer of this display's Spaces than the Monitors entry")
        }
        entry["ManagedSpaceIDs"] = newIDs

        var newMonitors = monitors
        newMonitors[display.monitorIndex] = monitor
        var newOrdering = ordering
        newOrdering[orderingIndex] = entry
        guard let step = setting(newMonitors, at: monitorsPath[...], in: config),
              let result = setting(newOrdering, at: orderingPath[...], in: step) else {
            throw SpaceOrderFileError.unexpectedShape("could not store the new arrays at their key paths")
        }

        try verify(result, original: inspection, displayID: display.displayIdentifier, expected: newOrderUUIDs)
        return result
    }

    /// Re-reads the result and checks it is exactly the original with one display's order changed.
    private static func verify(_ result: [String: Any], original: StoredInspection, displayID: String,
                               expected: [String]) throws {
        let after = inspect(result)
        guard after.layout == original.layout,
              after.monitorEntryCount == original.monitorEntryCount,
              after.staleMonitorCount == original.staleMonitorCount,
              after.displays.count == original.displays.count else {
            throw SpaceOrderFileError.unexpectedShape("the result does not have the layout of the original")
        }
        for (old, new) in zip(original.displays, after.displays) {
            if old.displayIdentifier.caseInsensitiveCompare(displayID) == .orderedSame {
                guard new.monitorUUIDs == expected, new.orderingLiveUUIDs == expected,
                      new.orderingIndex == old.orderingIndex,
                      Set(new.orderingUUIDs ?? []) == Set(old.orderingUUIDs ?? []),
                      new.staleOrderingUUIDs == old.staleOrderingUUIDs else {
                    throw SpaceOrderFileError.spaceSetMismatch("the result does not hold the requested order in both places")
                }
            } else if new != old {
                throw SpaceOrderFileError.spaceSetMismatch("another display (\(old.displayIdentifier)) would change")
            }
        }
    }

    private static func describe(_ uuids: [String]) -> String {
        uuids.map { $0.isEmpty ? "\"\" (first Desktop)" : String($0.prefix(8)) }.joined(separator: ", ")
    }

    // MARK: Domain access

    /// Every key of com.apple.spaces for the current user (any host), read through cfprefsd.
    public static func readDomain() throws -> [String: Any] {
        let app = domain as CFString
        CFPreferencesAppSynchronize(app)
        guard let keys = CFPreferencesCopyKeyList(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty else {
            throw SpaceOrderFileError.domainUnreadable("the domain has no keys")
        }
        var result: [String: Any] = [:]
        for key in keys {
            if let value = CFPreferencesCopyAppValue(key as CFString, app) { result[key] = value }
        }
        return result
    }

    /// Reads a plist file (a backup written by `backup`) as a dictionary.
    public static func readBackup(_ file: URL) throws -> [String: Any] {
        let data: Data
        do { data = try Data(contentsOf: file) } catch {
            throw SpaceOrderFileError.backupFailed("cannot read \(file.path): \(error.localizedDescription)")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            throw SpaceOrderFileError.backupFailed("\(file.path) is not a property list dictionary")
        }
        return dict
    }

    /// Stores every top-level key of `config` that differs from what is stored now, then synchronizes and reads
    /// the keys back. Keys that are not in `config` are left alone.
    public static func write(_ config: [String: Any]) throws {
        let app = domain as CFString
        let current = try readDomain()
        var changed: [String] = []
        for (key, value) in config where !isEqual(value, current[key]) {
            CFPreferencesSetAppValue(key as CFString, value as AnyObject, app)
            changed.append(key)
        }
        guard CFPreferencesAppSynchronize(app) else {
            throw SpaceOrderFileError.writeFailed("CFPreferencesAppSynchronize returned false")
        }
        let readBack = try readDomain()
        for key in changed where !isEqual(config[key], readBack[key]) {
            throw SpaceOrderFileError.writeFailed("\(key) did not read back as written")
        }
    }

    static func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return (a as AnyObject).isEqual(b as AnyObject)
    }

    // MARK: Backup / restore

    /// Saves the domain into `folder`: `defaults export` as com.apple.spaces-<stamp>.plist (the file `restore`
    /// imports) and a byte copy of ~/Library/Preferences/com.apple.spaces.plist next to it as
    /// com.apple.spaces-<stamp>.raw.plist. Returns the export file. Throws when the export is missing or not a
    /// plist that holds SpacesDisplayConfiguration; a failed raw copy is not an error.
    public static func backup(to folder: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw SpaceOrderFileError.backupFailed("cannot create \(folder.path): \(error.localizedDescription)")
        }
        let stamp = stampFormatter.string(from: Date())
        var export = folder.appendingPathComponent("\(domain)-\(stamp).plist")
        var counter = 2
        while FileManager.default.fileExists(atPath: export.path)
            || FileManager.default.fileExists(atPath: rawCopyURL(forBackup: export).path) {
            export = folder.appendingPathComponent("\(domain)-\(stamp)-\(counter).plist")
            counter += 1
        }

        let result = try runProcess("/usr/bin/defaults", ["export", domain, export.path])
        guard result.status == 0 else {
            throw SpaceOrderFileError.backupFailed("defaults export exited \(result.status): \(result.stderr)")
        }
        let exported = try readBackup(export)
        guard exported[rootKey] != nil else {
            throw SpaceOrderFileError.backupFailed("the export has no \(rootKey) key, so it is not usable as a backup")
        }

        let raw = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(domain).plist")
        try? FileManager.default.copyItem(at: raw, to: rawCopyURL(forBackup: export))
        return export
    }

    /// Where `backup` puts the raw copy that belongs to an export file.
    public static func rawCopyURL(forBackup export: URL) -> URL {
        export.deletingPathExtension().appendingPathExtension("raw.plist")
    }

    /// Replaces the whole domain with the contents of a backup file (`defaults import`). Does not restart the Dock.
    public static func restore(from file: URL) throws {
        let dict = try readBackup(file)
        guard dict[rootKey] != nil else {
            throw SpaceOrderFileError.backupFailed("\(file.path) has no \(rootKey) key; refusing to import it")
        }
        let result = try runProcess("/usr/bin/defaults", ["import", domain, file.path])
        guard result.status == 0 else {
            throw SpaceOrderFileError.commandFailed("defaults import exited \(result.status): \(result.stderr)")
        }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: Dock

    /// pid of this user's Dock process, nil when it is not running.
    public static func dockPID() -> Int32? {
        guard let result = try? runProcess("/usr/bin/pgrep", ["-x", "-u", String(getuid()), "Dock"]),
              result.status == 0 else { return nil }
        return result.stdout.split(whereSeparator: \.isNewline).first.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// `killall Dock`, then waits until a new Dock process runs and SpaceReader answers again. `timeout` (15 s)
    /// covers both waits together. Throws `dockDidNotRestart` when either does not happen in time.
    @discardableResult
    public static func restartDock(timeout: TimeInterval = 15) throws -> DockRestartResult {
        let old = dockPID()
        let started = ProcessInfo.processInfo.systemUptime
        let kill = try runProcess("/usr/bin/killall", ["Dock"])
        guard kill.status == 0 else {
            throw SpaceOrderFileError.commandFailed("killall Dock exited \(kill.status): \(kill.stderr.isEmpty ? "the Dock was not running" : kill.stderr)")
        }

        var newPID: Int32?
        let dockTime = waitUntil(timeout: timeout, interval: 0.25) {
            if let pid = dockPID(), pid != old {
                newPID = pid
                return true
            }
            return false
        }
        guard dockTime != nil, let newPID else {
            throw SpaceOrderFileError.dockDidNotRestart("The Dock did not come back within \(Int(timeout)) s")
        }
        let afterDock = ProcessInfo.processInfo.systemUptime - started

        let remaining = max(0.5, timeout - afterDock)
        let answered = waitUntil(timeout: remaining, interval: 0.25) {
            ((try? SpaceReader.displays()) ?? []).contains { !$0.spaces.isEmpty }
        }
        guard answered != nil else {
            throw SpaceOrderFileError.dockDidNotRestart("The Dock is running again but SpaceReader did not answer within \(Int(timeout)) s")
        }
        return DockRestartResult(oldPID: old, newPID: newPID, secondsUntilDock: afterDock,
                                 secondsUntilSpaces: ProcessInfo.processInfo.systemUptime - started)
    }

    // MARK: Processes

    struct ProcessOutput {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func runProcess(_ path: String, _ arguments: [String]) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            throw SpaceOrderFileError.commandFailed("cannot run \(path): \(error.localizedDescription)")
        }
        // Output is tiny, so reading one pipe after the other cannot fill a pipe buffer and block the child.
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessOutput(status: process.terminationStatus,
                             stdout: String(decoding: stdoutData, as: UTF8.self),
                             stderr: String(decoding: stderrData, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
