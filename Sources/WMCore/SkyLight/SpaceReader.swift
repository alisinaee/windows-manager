import AppKit
import Foundation

// Reads macOS Spaces (Desktops and full-screen Spaces) through private SkyLight calls.
// The C signatures follow the MIT-licensed yabai project (src/misc/extern.h); the code is our own.

/// What kind of Space this is. Raw values are SkyLight's `type` key.
public enum SpaceKind: Codable, Equatable, Hashable {
    /// type 0: a normal Desktop.
    case desktop
    /// type 4: a full-screen app (or Split View) Space.
    case fullscreen
    /// Any other type, with the raw number (2 = system, 5 and 6 only appear inside tile data).
    case other(Int)

    public init(rawType: Int) {
        switch rawType {
        case 0: self = .desktop
        case 4: self = .fullscreen
        default: self = .other(rawType)
        }
    }

    public var rawType: Int {
        switch self {
        case .desktop: return 0
        case .fullscreen: return 4
        case .other(let raw): return raw
        }
    }

    // JSON form is a readable string: "desktop", "fullscreen" or "other:<raw>".
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        switch text {
        case "desktop": self = .desktop
        case "fullscreen": self = .fullscreen
        default:
            guard text.hasPrefix("other:"), let raw = Int(text.dropFirst("other:".count)) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Unknown Space kind \(text)"))
            }
            self = .other(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .desktop: try container.encode("desktop")
        case .fullscreen: try container.encode("fullscreen")
        case .other(let raw): try container.encode("other:\(raw)")
        }
    }
}

/// One Space on one display.
public struct SpaceInfo: Codable, Equatable {
    /// SkyLight Space id ("id64", same as "ManagedSpaceID").
    public var id: UInt64
    /// Space uuid; the first Desktop of a display can report an empty string.
    public var uuid: String
    public var kind: SpaceKind
    /// 0-based position on its display, in Mission Control order (array order).
    public var index: Int
    public var isCurrent: Bool
    /// pid of the app that owns a full-screen Space.
    public var fullScreenOwnerPID: Int32?
    /// Window ids of the full-screen window(s): "fs_wid" and the TileLayoutManager > TileSpaces entries.
    /// More than one id means Split View.
    public var fullScreenWindowIDs: [UInt32]
    /// Names of the apps that own a full-screen Space (TileSpaces "appName" plus the pid's running app).
    public var ownerAppNames: [String]

    public init(id: UInt64, uuid: String, kind: SpaceKind, index: Int, isCurrent: Bool,
                fullScreenOwnerPID: Int32? = nil, fullScreenWindowIDs: [UInt32] = [],
                ownerAppNames: [String] = []) {
        self.id = id
        self.uuid = uuid
        self.kind = kind
        self.index = index
        self.isCurrent = isCurrent
        self.fullScreenOwnerPID = fullScreenOwnerPID
        self.fullScreenWindowIDs = fullScreenWindowIDs
        self.ownerAppNames = ownerAppNames
    }

    /// A full-screen Space that holds more than one window (Split View).
    public var isSplitView: Bool { kind == .fullscreen && fullScreenWindowIDs.count > 1 }
}

/// All Spaces of one display, in Mission Control order.
public struct DisplaySpaces: Codable, Equatable {
    /// As SkyLight reports it: "Main" or the display UUID.
    public var displayIdentifier: String
    /// Name from NSScreen when a screen matches this display, otherwise nil.
    public var displayName: String?
    public var currentSpaceID: UInt64
    public var spaces: [SpaceInfo]

    public init(displayIdentifier: String, displayName: String?, currentSpaceID: UInt64, spaces: [SpaceInfo]) {
        self.displayIdentifier = displayIdentifier
        self.displayName = displayName
        self.currentSpaceID = currentSpaceID
        self.spaces = spaces
    }

    public var currentSpace: SpaceInfo? { spaces.first { $0.id == currentSpaceID } }

    /// The "Desktop N" number Mission Control shows: 1-based position among Desktops only
    /// (full-screen Spaces are not counted). Nil for full-screen and other Spaces.
    public func desktopNumber(of space: SpaceInfo) -> Int? {
        guard space.kind == .desktop else { return nil }
        return spaces.filter { $0.kind == .desktop && $0.index <= space.index }.count
    }
}

public enum SpaceReaderError: Error, LocalizedError, Equatable {
    case skyLightNotLoaded(String?)
    case symbolMissing(String)
    case noData(String)

    public var errorDescription: String? {
        switch self {
        case .skyLightNotLoaded(let detail):
            return "SkyLight could not be loaded" + (detail.map { ": \($0)" } ?? "")
        case .symbolMissing(let name):
            return "SkyLight does not export \(name) on this macOS version"
        case .noData(let what):
            return what
        }
    }
}

public enum SpaceReader {
    // MARK: Private C signatures (yabai extern.h)

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias GetActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias ManagedDisplayGetCurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias CopyWindowsWithOptionsAndTags = @convention(c) (
        Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
    ) -> Unmanaged<CFArray>?

    /// Space mask meaning "all kinds of Spaces" (current, other, full screen) for SLSCopySpacesForWindows.
    private static let allSpacesMask: Int32 = 0x7
    /// Option bits for SLSCopyWindowsWithOptionsAndTags: 0x2 = normal windows, 0x7 adds minimized / hidden ones.
    private static let allWindowsOptions: UInt32 = 0x7

    private static func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard PrivateSymbols.isLoaded else { throw SpaceReaderError.skyLightNotLoaded(PrivateSymbols.loadError) }
        guard let found = PrivateSymbols.lookup(name, as: type) else { throw SpaceReaderError.symbolMissing(name) }
        return found
    }

    private static func connectionID() throws -> Int32 {
        try symbol("SLSMainConnectionID", as: MainConnectionID.self)()
    }

    // MARK: Reading

    /// Every display with its Spaces, as SkyLight reports them right now.
    public static func displays() throws -> [DisplaySpaces] {
        let cid = try connectionID()
        let copy = try symbol("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
        guard let array = copy(cid)?.takeRetainedValue() else {
            throw SpaceReaderError.noData("SLSCopyManagedDisplaySpaces returned nothing")
        }
        let raw = (array as? [[String: Any]]) ?? []
        return parse(raw, lookups: .system(connection: cid))
    }

    /// For each window id, the Space ids it is on (several for windows set to "all Desktops").
    /// Every requested id is a key; a window that is on no Space maps to an empty list.
    public static func spaces(forWindows windows: [UInt32]) -> [UInt32: [UInt64]] {
        guard let cid = try? connectionID(),
              let copy = try? symbol("SLSCopySpacesForWindows", as: CopySpacesForWindows.self) else { return [:] }
        var result: [UInt32: [UInt64]] = [:]
        // The call returns one flat list for the whole input, so ask once per window.
        for window in windows {
            let input = [NSNumber(value: Int32(truncatingIfNeeded: window))] as CFArray
            let ids = (copy(cid, allSpacesMask, input)?.takeRetainedValue() as? [NSNumber]) ?? []
            result[window] = ids.map { $0.uint64Value }
        }
        return result
    }

    /// The Space that is active on the display with keyboard focus (0 when it cannot be read).
    public static func activeSpaceID() -> UInt64 {
        guard let cid = try? connectionID(),
              let active = try? symbol("SLSGetActiveSpace", as: GetActiveSpace.self) else { return 0 }
        return active(cid)
    }

    /// Window ids on the given Spaces, including Spaces that are not visible right now (Accessibility only
    /// sees the current Space). The list also holds non-window items such as menu bar and wallpaper
    /// windows, so join it with `CGWindowList` data before showing it to people.
    public static func windows(onSpaces spaces: [UInt64]) -> [UInt32] {
        guard !spaces.isEmpty,
              let cid = try? connectionID(),
              let copy = try? symbol("SLSCopyWindowsWithOptionsAndTags", as: CopyWindowsWithOptionsAndTags.self)
        else { return [] }
        let input = spaces.map { NSNumber(value: Int64(bitPattern: $0)) } as CFArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let list = copy(cid, 0, input, allWindowsOptions, &setTags, &clearTags)?.takeRetainedValue()
        return ((list as? [NSNumber]) ?? []).map { UInt32(truncatingIfNeeded: $0.int64Value) }
    }

    // MARK: Parsing (pure)

    /// Optional lookups `parse` may use. `.none` keeps `parse` free of system calls.
    public struct Lookups {
        /// Display identifier ("Main" or a UUID) -> screen name.
        public var displayName: (String) -> String?
        /// pid -> app name.
        public var appName: (Int32) -> String?
        /// Display identifier -> its current Space id; used only when the raw data has none.
        public var currentSpace: (String) -> UInt64?

        public init(displayName: @escaping (String) -> String? = { _ in nil },
                    appName: @escaping (Int32) -> String? = { _ in nil },
                    currentSpace: @escaping (String) -> UInt64? = { _ in nil }) {
            self.displayName = displayName
            self.appName = appName
            self.currentSpace = currentSpace
        }

        public static let none = Lookups()

        /// NSScreen names, NSRunningApplication names and SLSManagedDisplayGetCurrentSpace.
        public static func system(connection cid: Int32?) -> Lookups {
            Lookups(
                displayName: { SpaceReader.screenName(forDisplayIdentifier: $0) },
                appName: { NSRunningApplication(processIdentifier: $0)?.localizedName },
                currentSpace: { identifier in
                    guard let cid,
                          let get = try? SpaceReader.symbol("SLSManagedDisplayGetCurrentSpace",
                                                            as: ManagedDisplayGetCurrentSpace.self) else { return nil }
                    let id = get(cid, identifier as CFString)
                    return id == 0 ? nil : id
                }
            )
        }
    }

    /// Turns the raw `SLSCopyManagedDisplaySpaces` array into `DisplaySpaces`.
    /// Pure: it only touches the system through `lookups`.
    public static func parse(_ raw: [[String: Any]], lookups: Lookups = .none) -> [DisplaySpaces] {
        raw.map { display in
            let identifier = (display["Display Identifier"] as? String) ?? "Main"

            var currentID = spaceID(display["Current Space"] as? [String: Any]) ?? 0
            if currentID == 0, let fallback = lookups.currentSpace(identifier) { currentID = fallback }

            var spaces: [SpaceInfo] = []
            for entry in (display["Spaces"] as? [[String: Any]]) ?? [] {
                guard let id = spaceID(entry) else { continue }
                spaces.append(parseSpace(entry, id: id, index: spaces.count, isCurrent: id == currentID,
                                         appName: lookups.appName))
            }
            return DisplaySpaces(displayIdentifier: identifier, displayName: lookups.displayName(identifier),
                                 currentSpaceID: currentID, spaces: spaces)
        }
    }

    private static func parseSpace(_ entry: [String: Any], id: UInt64, index: Int, isCurrent: Bool,
                                   appName: (Int32) -> String?) -> SpaceInfo {
        let kind = SpaceKind(rawType: Int(number(entry["type"]) ?? -1))
        let tiles = ((entry["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]]) ?? []

        var windowIDs: [UInt32] = []
        func addWindow(_ value: Any?) {
            guard let n = number(value), n > 0, n <= Int64(UInt32.max) else { return }
            let wid = UInt32(n)
            if !windowIDs.contains(wid) { windowIDs.append(wid) }
        }
        addWindow(entry["fs_wid"])
        for tile in tiles {
            addWindow(tile["fs_wid"])
            addWindow(tile["TileWindowID"])
        }

        var pids: [Int32] = []
        func addPID(_ value: Any?) {
            guard let n = number(value), n > 0, n <= Int64(Int32.max) else { return }
            let pid = Int32(n)
            if !pids.contains(pid) { pids.append(pid) }
        }
        addPID(entry["pid"])
        for tile in tiles { addPID(tile["pid"]) }

        var names: [String] = []
        func addName(_ value: String?) {
            guard let value, !value.isEmpty, !names.contains(value) else { return }
            names.append(value)
        }
        for tile in tiles { addName(tile["appName"] as? String) }
        for pid in pids { addName(appName(pid)) }

        return SpaceInfo(id: id, uuid: (entry["uuid"] as? String) ?? "", kind: kind, index: index,
                         isCurrent: isCurrent, fullScreenOwnerPID: pids.first, fullScreenWindowIDs: windowIDs,
                         ownerAppNames: names)
    }

    private static func spaceID(_ dict: [String: Any]?) -> UInt64? {
        guard let dict, let n = number(dict["id64"]) ?? number(dict["ManagedSpaceID"]), n >= 0 else { return nil }
        return UInt64(n)
    }

    private static func number(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    // MARK: Display names

    /// NSScreen name for a SkyLight display identifier: "Main" is the main display, anything else is
    /// matched against each screen's CGDisplay UUID.
    static func screenName(forDisplayIdentifier identifier: String) -> String? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            if identifier == "Main" {
                if displayID == CGMainDisplayID() { return screen.localizedName }
            } else if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
                      let text = CFUUIDCreateString(nil, uuid) as String?,
                      text.caseInsensitiveCompare(identifier) == .orderedSame {
                return screen.localizedName
            }
        }
        return nil
    }
}
