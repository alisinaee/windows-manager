import CoreGraphics
import Foundation

// The profile data model (phase P2.4): a saved workspace such as "Home" or "Work".
// A profile records which apps and windows exist, on which monitor, frame, Desktop or full-screen Space,
// and the order of the Spaces on every monitor. Every frame uses global top-left coordinates
// (see Contracts.swift). Files are written by `ProfileStore`.

/// What kind of Space a `SpaceSnapshot` describes. Stored as a plain string so the file stays readable
/// and does not depend on SkyLight's raw type numbers.
public enum SavedSpaceKind: String, Codable, Hashable, Sendable {
    /// A normal Desktop.
    case desktop
    /// A native full-screen app or Split View Space.
    case fullScreen
    /// Anything else (system Spaces, unknown types).
    case other

    public init(_ kind: SpaceKind) {
        switch kind {
        case .desktop: self = .desktop
        case .fullscreen: self = .fullScreen
        case .other: self = .other
        }
    }
}

/// One Space of one display, in Mission Control order.
public struct SpaceSnapshot: Codable, Hashable, Sendable, Identifiable {
    /// `DisplayIdentity.uuid` of the display this Space belongs to.
    public var displayUUID: String
    /// 0-based position in Mission Control order on that display (full-screen Spaces count).
    public var position: Int
    public var kind: SavedSpaceKind
    /// 1-based "Desktop N" number, only for `.desktop` Spaces.
    public var desktopNumber: Int?
    /// `WindowSnapshot.id` of the window(s) that own a full-screen Space: one normally, two for Split View.
    public var fullScreenWindowIDs: [UUID]

    public init(displayUUID: String, position: Int, kind: SavedSpaceKind, desktopNumber: Int? = nil,
                fullScreenWindowIDs: [UUID] = []) {
        self.displayUUID = displayUUID
        self.position = position
        self.kind = kind
        self.desktopNumber = desktopNumber
        self.fullScreenWindowIDs = fullScreenWindowIDs
    }

    /// Not stored: a Space is identified by its display and position.
    public var id: String { "\(displayUUID)#\(position)" }

    /// A full-screen Space that holds more than one window (Split View).
    public var isSplitView: Bool { kind == .fullScreen && fullScreenWindowIDs.count > 1 }

    private enum CodingKeys: String, CodingKey {
        case displayUUID, position, kind, desktopNumber, fullScreenWindowIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayUUID = try c.decode(String.self, forKey: .displayUUID)
        position = try c.decode(Int.self, forKey: .position)
        kind = try c.decode(SavedSpaceKind.self, forKey: .kind)
        desktopNumber = try c.decodeIfPresent(Int.self, forKey: .desktopNumber)
        fullScreenWindowIDs = try c.decodeIfPresent([UUID].self, forKey: .fullScreenWindowIDs) ?? []
    }
}

/// How a saved window title is compared with a live window title when windows are matched on restore.
/// JSON form: `{"kind": "any"}` or `{"kind": "exact" | "contains" | "regex", "value": "..."}`.
public enum TitleMatch: Codable, Hashable, Sendable {
    /// Ignore the title.
    case any
    case exact(String)
    case contains(String)
    case regex(String)

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "any":
            self = .any
        case "exact":
            self = .exact(try c.decode(String.self, forKey: .value))
        case "contains":
            self = .contains(try c.decode(String.self, forKey: .value))
        case "regex":
            self = .regex(try c.decode(String.self, forKey: .value))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [CodingKeys.kind],
                                                    debugDescription: "Unknown title match kind \(kind)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .any:
            try c.encode("any", forKey: .kind)
        case .exact(let value):
            try c.encode("exact", forKey: .kind)
            try c.encode(value, forKey: .value)
        case .contains(let value):
            try c.encode("contains", forKey: .kind)
            try c.encode(value, forKey: .value)
        case .regex(let value):
            try c.encode("regex", forKey: .kind)
            try c.encode(value, forKey: .value)
        }
    }
}

/// Where a `WindowSnapshot` came from. Nil in files from before the Profile Studio: those are captured windows.
public enum WindowOrigin: String, Codable, Hashable, Sendable {
    /// Recorded from the live workspace by a capture.
    case captured
    /// Placed by hand in the Profile Studio Builder; the app may or may not open such a window.
    case planned
}

/// One window as it was when the profile was captured.
public struct WindowSnapshot: Codable, Hashable, Sendable, Identifiable {
    /// Stable id inside this profile; `SpaceSnapshot.fullScreenWindowIDs` points at it.
    public var id: UUID
    public var app: AppRef
    /// Window title at capture time, for people and for matching.
    public var title: String?
    public var titleMatch: TitleMatch
    /// Document path (AXDocument) when the app exposes one.
    public var documentPath: String?
    /// Order among this app's windows at capture time (0-based).
    public var indexInApp: Int
    /// `DisplayIdentity.uuid` of the display the window was on.
    public var displayUUID: String
    /// Window frame, global top-left coordinates.
    public var frame: CGRect
    /// Frame as fractions (0...1) of the display's `visibleFrame`, used when the monitor size differs.
    public var relativeFrame: CGRect
    public var placement: SpacePlacement
    public var isFullScreen: Bool
    public var isMinimized: Bool
    /// Stacking order among captured windows, 0 = front.
    public var zIndex: Int
    /// The user can untick a window to leave it out of a restore.
    public var restore: Bool
    /// nil = captured (older files and every capture). `.planned` = placed in the Builder.
    public var origin: WindowOrigin?
    /// Name of the Layout zone the window was snapped to ("Left half"), for display only; nil when not snapped.
    public var zoneName: String?

    public init(id: UUID = UUID(), app: AppRef, title: String? = nil, titleMatch: TitleMatch = .any,
                documentPath: String? = nil, indexInApp: Int = 0, displayUUID: String, frame: CGRect,
                relativeFrame: CGRect, placement: SpacePlacement, isFullScreen: Bool = false,
                isMinimized: Bool = false, zIndex: Int = 0, restore: Bool = true,
                origin: WindowOrigin? = nil, zoneName: String? = nil) {
        self.id = id
        self.app = app
        self.title = title
        self.titleMatch = titleMatch
        self.documentPath = documentPath
        self.indexInApp = indexInApp
        self.displayUUID = displayUUID
        self.frame = frame
        self.relativeFrame = relativeFrame
        self.placement = placement
        self.isFullScreen = isFullScreen
        self.isMinimized = isMinimized
        self.zIndex = zIndex
        self.restore = restore
        self.origin = origin
        self.zoneName = zoneName
    }

    private enum CodingKeys: String, CodingKey {
        case id, app, title, titleMatch, documentPath, indexInApp, displayUUID, frame, relativeFrame
        case placement, isFullScreen, isMinimized, zIndex, restore, origin, zoneName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        app = try c.decode(AppRef.self, forKey: .app)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        titleMatch = try c.decodeIfPresent(TitleMatch.self, forKey: .titleMatch) ?? .any
        documentPath = try c.decodeIfPresent(String.self, forKey: .documentPath)
        indexInApp = try c.decode(Int.self, forKey: .indexInApp)
        displayUUID = try c.decode(String.self, forKey: .displayUUID)
        frame = try c.decode(CGRect.self, forKey: .frame)
        relativeFrame = try c.decode(CGRect.self, forKey: .relativeFrame)
        placement = try c.decode(SpacePlacement.self, forKey: .placement)
        isFullScreen = try c.decode(Bool.self, forKey: .isFullScreen)
        isMinimized = try c.decode(Bool.self, forKey: .isMinimized)
        zIndex = try c.decode(Int.self, forKey: .zIndex)
        restore = try c.decodeIfPresent(Bool.self, forKey: .restore) ?? true
        origin = try c.decodeIfPresent(WindowOrigin.self, forKey: .origin)
        zoneName = try c.decodeIfPresent(String.self, forKey: .zoneName)
    }
}

/// What a restore does with apps that are running but not part of the profile.
public enum OtherAppsPolicy: String, Codable, Hashable, Sendable {
    /// Leave them alone.
    case leave
    /// Hide them.
    case hide
    /// Quit them.
    case quit
}

/// Per-profile restore switches.
public struct ProfileOptions: Codable, Hashable, Sendable {
    public var launchMissingApps: Bool
    public var restoreFullScreen: Bool
    public var restoreSpaces: Bool
    public var restoreSpaceOrder: Bool
    public var otherApps: OtherAppsPolicy
    /// Global shortcut that restores this profile, e.g. "ctrl+opt+1".
    public var hotkey: String?
    /// Create missing Desktops on the monitors before placing windows (the engine also honors the global
    /// setting). Written only when true, so profiles that never set it re-encode byte-identical.
    public var addMissingDesktops: Bool

    public init(launchMissingApps: Bool = true, restoreFullScreen: Bool = true, restoreSpaces: Bool = true,
                restoreSpaceOrder: Bool = true, otherApps: OtherAppsPolicy = .leave, hotkey: String? = nil,
                addMissingDesktops: Bool = false) {
        self.launchMissingApps = launchMissingApps
        self.restoreFullScreen = restoreFullScreen
        self.restoreSpaces = restoreSpaces
        self.restoreSpaceOrder = restoreSpaceOrder
        self.otherApps = otherApps
        self.hotkey = hotkey
        self.addMissingDesktops = addMissingDesktops
    }

    private enum CodingKeys: String, CodingKey {
        case launchMissingApps, restoreFullScreen, restoreSpaces, restoreSpaceOrder, otherApps, hotkey
        case addMissingDesktops
    }

    // Every switch falls back to its default, so a newer option never breaks an older file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchMissingApps = try c.decodeIfPresent(Bool.self, forKey: .launchMissingApps) ?? true
        restoreFullScreen = try c.decodeIfPresent(Bool.self, forKey: .restoreFullScreen) ?? true
        restoreSpaces = try c.decodeIfPresent(Bool.self, forKey: .restoreSpaces) ?? true
        restoreSpaceOrder = try c.decodeIfPresent(Bool.self, forKey: .restoreSpaceOrder) ?? true
        otherApps = try c.decodeIfPresent(OtherAppsPolicy.self, forKey: .otherApps) ?? .leave
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey)
        addMissingDesktops = try c.decodeIfPresent(Bool.self, forKey: .addMissingDesktops) ?? false
    }

    // Written by hand, not synthesized, so a `false` addMissingDesktops adds no key to existing files.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(launchMissingApps, forKey: .launchMissingApps)
        try c.encode(restoreFullScreen, forKey: .restoreFullScreen)
        try c.encode(restoreSpaces, forKey: .restoreSpaces)
        try c.encode(restoreSpaceOrder, forKey: .restoreSpaceOrder)
        try c.encode(otherApps, forKey: .otherApps)
        try c.encodeIfPresent(hotkey, forKey: .hotkey)
        if addMissingDesktops { try c.encode(true, forKey: .addMissingDesktops) }
    }
}

/// A saved workspace.
public struct Profile: Codable, Hashable, Sendable, Identifiable {
    /// The schema version this build writes and reads.
    public static let currentSchemaVersion = 1
    /// SF Symbol used when no icon is chosen.
    public static let defaultIcon = "rectangle.3.group"

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    /// SF Symbol name.
    public var icon: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Identifies the set of monitors the profile was captured on, so the right profile variant can be picked.
    public var monitorSetKey: String
    public var displays: [DisplayIdentity]
    public var spaces: [SpaceSnapshot]
    public var windows: [WindowSnapshot]
    public var options: ProfileOptions
    public var notes: String?
    /// Whether Stage Manager was on when the profile was captured; nil in profiles saved before P3.8.
    public var stageManagerOn: Bool?
    /// Launch order and timing; nil = launch every closed app in parallel, as before the launch order existed.
    public var launchPlan: LaunchPlan?

    /// `updatedAt` defaults to `createdAt`.
    public init(schemaVersion: Int = Profile.currentSchemaVersion, id: UUID = UUID(), name: String,
                icon: String = Profile.defaultIcon, createdAt: Date = Date(), updatedAt: Date? = nil,
                monitorSetKey: String, displays: [DisplayIdentity] = [], spaces: [SpaceSnapshot] = [],
                windows: [WindowSnapshot] = [], options: ProfileOptions = ProfileOptions(), notes: String? = nil,
                stageManagerOn: Bool? = nil, launchPlan: LaunchPlan? = nil) {
        self.stageManagerOn = stageManagerOn
        self.launchPlan = launchPlan
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.icon = icon
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.monitorSetKey = monitorSetKey
        self.displays = displays
        self.spaces = spaces
        self.windows = windows
        self.options = options
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, icon, createdAt, updatedAt, monitorSetKey, displays, spaces, windows
        case options, notes, stageManagerOn, launchPlan
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? Profile.defaultIcon
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        monitorSetKey = try c.decode(String.self, forKey: .monitorSetKey)
        displays = try c.decode([DisplayIdentity].self, forKey: .displays)
        spaces = try c.decode([SpaceSnapshot].self, forKey: .spaces)
        windows = try c.decode([WindowSnapshot].self, forKey: .windows)
        options = try c.decodeIfPresent(ProfileOptions.self, forKey: .options) ?? ProfileOptions()
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        stageManagerOn = try c.decodeIfPresent(Bool.self, forKey: .stageManagerOn)
        launchPlan = try c.decodeIfPresent(LaunchPlan.self, forKey: .launchPlan)
    }

    // MARK: Helpers

    /// Two refs are the same app when both have a bundle id and the ids are equal (ignoring case, like WindowMatcher), otherwise when the
    /// names are equal (ignoring case). A path alone never decides: it can change between machines.
    static func isSameApp(_ a: AppRef, _ b: AppRef) -> Bool {
        if let x = a.bundleID, let y = b.bundleID { return x.caseInsensitiveCompare(y) == .orderedSame }
        return a.name.caseInsensitiveCompare(b.name) == .orderedSame
    }

    /// The windows of one app, in the order they had inside the app at capture (`indexInApp`).
    public func windows(for app: AppRef) -> [WindowSnapshot] {
        windows.enumerated()
            .filter { Self.isSameApp($0.element.app, app) }
            .sorted { ($0.element.indexInApp, $0.offset) < ($1.element.indexInApp, $1.offset) }
            .map(\.element)
    }

    /// Each app once, in the order it first appears in `windows`.
    public var apps: [AppRef] {
        var result: [AppRef] = []
        for window in windows where !result.contains(where: { Self.isSameApp($0, window.app) }) {
            result.append(window.app)
        }
        return result
    }

    /// `apps` plus the launch-only apps of the launch plan (apps that launch without a window to place).
    public var launchApps: [AppRef] {
        var result = apps
        for item in launchPlan?.items ?? [] where item.withoutWindows && !result.contains(where: { Self.isSameApp($0, item.app) }) {
            result.append(item.app)
        }
        return result
    }

    /// The Spaces of one display in Mission Control order.
    public func spaces(onDisplay displayUUID: String) -> [SpaceSnapshot] {
        spaces.filter { $0.displayUUID == displayUUID }.sorted { $0.position < $1.position }
    }

    /// Everything wrong with the profile, as sentences for people. Empty means the profile is consistent.
    public func validate() -> [String] {
        var problems: [String] = []

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("The profile name is empty.")
        }
        if schemaVersion > Profile.currentSchemaVersion {
            problems.append("The profile uses schema version \(schemaVersion), newer than the supported \(Profile.currentSchemaVersion).")
        }

        let displayIDs = Set(displays.map(\.uuid))
        for uuid in Self.duplicates(displays.map(\.uuid)) {
            problems.append("Display \(uuid) is listed more than once.")
        }

        let windowIDs = Set(windows.map(\.id))
        for id in Self.duplicates(windows.map(\.id)) {
            problems.append("Window id \(id.uuidString) is used by more than one window.")
        }
        for window in windows where !displayIDs.contains(window.displayUUID) {
            problems.append("Window \(window.app.name) (\(window.id.uuidString)) is on display \(window.displayUUID), which the profile does not list.")
        }

        for space in spaces where !displayIDs.contains(space.displayUUID) {
            problems.append("Space \(space.position) is on display \(space.displayUUID), which the profile does not list.")
        }
        for key in Self.duplicates(spaces.map { "\($0.displayUUID)\u{0}\($0.position)" }) {
            let parts = key.split(separator: "\u{0}", omittingEmptySubsequences: false)
            problems.append("Display \(parts.first ?? "?") has more than one Space at position \(parts.last ?? "?").")
        }

        var owners: [UUID: Int] = [:]
        for space in spaces {
            for id in space.fullScreenWindowIDs {
                if !windowIDs.contains(id) {
                    problems.append("Space \(space.position) on display \(space.displayUUID) points at window \(id.uuidString), which is not in the profile.")
                }
                owners[id, default: 0] += 1
            }
        }
        for id in windows.map(\.id) where (owners[id] ?? 0) > 1 {
            problems.append("Window \(id.uuidString) owns more than one full-screen Space.")
            owners[id] = nil
        }
        return problems
    }

    /// Values that occur more than once, each reported once, in first-duplicate order.
    private static func duplicates<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        var reported = Set<T>()
        var result: [T] = []
        for item in items {
            if !seen.insert(item).inserted, reported.insert(item).inserted { result.append(item) }
        }
        return result
    }
}
