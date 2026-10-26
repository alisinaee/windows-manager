import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Reads the whole workspace in one pass (phase P2.5): every monitor, every Desktop and full-screen Space,
// and every normal window with the Space it lives on. The result, `WorkspaceScan`, is plain data. It feeds
// `ProfileCapture` (save a profile) and the restore engine (`WindowMatcher` works on `[LiveWindow]`).
//
// Where the data comes from:
//  - monitors: `DisplayMap.current()`;
//  - Spaces: `SpaceReader.displays()` (SkyLight), matched to the monitors by display UUID;
//  - windows: `WindowCatalog.all()` (CGWindowList `.optionAll` + `SpaceReader.spaces(forWindows:)`), which
//    sees windows on every Space. The Accessibility API only sees windows on the Space that is visible on
//    each display (plus minimized windows), so document paths, minimized state and missing titles are only
//    known for those. While the screen is locked AX returns placeholders, so it is skipped then.
//
// `scan()` talks to the system; everything it decides is made by pure functions (`assemble`, `isUserWindow`,
// `fullScreenOwners`, `placement(for:in:)`) so it can be tested with fixtures.

/// What the scanner leaves out or reads.
public struct ScanOptions: Hashable, Sendable {
    /// Apps to ignore, by bundle id (case-insensitive), on top of the built-in list (our own app, Dock,
    /// Control Center, Stage Manager, ...).
    public var excludedBundleIDs: Set<String>
    /// A full-screen Space can hold windows that do not own it: toolbar and menu bar overlays, such as Chrome's
    /// 1920x124 strip. They cannot be restored on their own, so they are left out unless this is true.
    public var includeFullScreenHelperWindows: Bool
    /// False skips the Accessibility API: no document paths, no minimized state, no AX titles.
    public var readAccessibility: Bool

    public init(excludedBundleIDs: Set<String> = [], includeFullScreenHelperWindows: Bool = false,
                readAccessibility: Bool = true) {
        self.excludedBundleIDs = excludedBundleIDs
        self.includeFullScreenHelperWindows = includeFullScreenHelperWindows
        self.readAccessibility = readAccessibility
    }
}

/// The Spaces of one monitor in Mission Control order.
public struct ScannedSpaces: Equatable, @unchecked Sendable {
    /// `DisplayIdentity.uuid` of the monitor.
    public var displayUUID: String
    /// How SkyLight named the monitor: "Main" or its UUID.
    public var skyLightIdentifier: String
    public var currentSpaceID: UInt64
    /// Mission Control order; `SpaceInfo.index` is the 0-based position.
    public var spaces: [SpaceInfo]

    public init(displayUUID: String, skyLightIdentifier: String? = nil, currentSpaceID: UInt64 = 0,
                spaces: [SpaceInfo]) {
        self.displayUUID = displayUUID
        self.skyLightIdentifier = skyLightIdentifier ?? displayUUID
        self.currentSpaceID = currentSpaceID
        self.spaces = spaces
    }

    public var desktops: [SpaceInfo] { spaces.filter { $0.kind == .desktop } }
    public var fullScreenSpaces: [SpaceInfo] { spaces.filter { $0.kind == .fullscreen } }

    public func space(withID id: UInt64) -> SpaceInfo? { spaces.first { $0.id == id } }

    /// The "Desktop N" number: 1-based position among Desktops only. Nil for other kinds of Space.
    public func desktopNumber(of space: SpaceInfo) -> Int? {
        guard space.kind == .desktop else { return nil }
        return spaces.filter { $0.kind == .desktop && $0.index <= space.index }.count
    }
}

/// Everything one scan found.
public struct WorkspaceScan: @unchecked Sendable {
    /// Connected monitors, main display first.
    public var displays: [DisplayIdentity]
    /// The Spaces of each monitor, in the order of `displays`.
    public var spaces: [ScannedSpaces]
    /// Normal user windows of every Space, front to back (the window server's order).
    public var windows: [LiveWindow]
    /// The Space with keyboard focus (0 when unknown).
    public var activeSpaceID: UInt64
    /// False when this process may not use the Accessibility API (no document paths, no minimized state).
    public var accessibilityTrusted: Bool
    /// True when the screen was locked: Accessibility data is missing.
    public var screenIsLocked: Bool
    /// Things a person should know about this scan (screen locked, Spaces that could not be matched, ...).
    public var notes: [String]
    public var scannedAt: Date
    /// Stage Manager on/off now; nil when unknown.
    public var stageManagerOn: Bool?

    public init(displays: [DisplayIdentity], spaces: [ScannedSpaces] = [], windows: [LiveWindow] = [],
                activeSpaceID: UInt64 = 0, accessibilityTrusted: Bool = true, screenIsLocked: Bool = false,
                notes: [String] = [], scannedAt: Date = Date(), stageManagerOn: Bool? = nil) {
        self.stageManagerOn = stageManagerOn
        self.displays = displays
        self.spaces = spaces
        self.windows = windows
        self.activeSpaceID = activeSpaceID
        self.accessibilityTrusted = accessibilityTrusted
        self.screenIsLocked = screenIsLocked
        self.notes = notes
        self.scannedAt = scannedAt
    }

    public func display(withUUID uuid: String) -> DisplayIdentity? {
        displays.first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
    }

    /// The Spaces of one monitor (UUID compared case-insensitively).
    public func spaces(onDisplay uuid: String) -> ScannedSpaces? {
        spaces.first { $0.displayUUID.caseInsensitiveCompare(uuid) == .orderedSame }
    }

    /// The window with this CGWindowID.
    public func window(withID id: UInt32) -> LiveWindow? { windows.first { $0.windowID == id } }
}

/// What the Accessibility API says about one window.
struct AXWindowDetails: Equatable {
    var title: String?
    var documentPath: String?
    var isMinimized: Bool?
    /// The window's real frame from Accessibility. The window server reports thumbnail-sized bounds for windows
    /// on inactive Spaces and under Stage Manager, so this is the size to trust for those.
    var frame: CGRect?
}

public enum WorkspaceScanner {
    /// Bundle id of Windows Manager itself.
    public static let ownBundleID = "dev.windowsmanager.WindowsManager"

    /// Window server owner names that never own a window a person would restore. "WindowManager" is the
    /// Stage Manager process: it adds "Gesture Blocking Overlay" and "App Icon Window" windows.
    static let excludedAppNames: Set<String> = [
        "dock", "window server", "control center", "systemuiserver", "notification center", "windowmanager",
    ]
    static let excludedBundleIDs: Set<String> = [
        ownBundleID.lowercased(), "com.apple.dock", "com.apple.controlcenter", "com.apple.systemuiserver",
        "com.apple.notificationcenterui", "com.apple.windowmanager",
    ]

    // MARK: Scan

    /// Reads monitors, Spaces and windows now. Read-only: nothing is moved, shown or hidden.
    public static func scan(options: ScanOptions = ScanOptions()) -> WorkspaceScan {
        let displays = DisplayMap.current()
        var notes: [String] = []

        var skyLight: [DisplaySpaces] = []
        do {
            skyLight = try SpaceReader.displays()
        } catch {
            notes.append("Spaces could not be read: \(error.localizedDescription)")
        }
        let catalog = WindowCatalog.all()

        let trusted = AXPermission.isTrusted()
        let locked = isScreenLocked()
        var ax: [UInt32: AXWindowDetails] = [:]
        if options.readAccessibility {
            if locked {
                notes.append("The screen is locked, so document paths and minimized windows could not be read.")
            } else if !trusted {
                notes.append("Accessibility access is not granted, so document paths and minimized windows could not be read.")
            } else {
                ax = readAccessibility(pids: accessibilityCandidates(catalog: catalog, options: options))
            }
        }

        var cache: [Int32: AppRef?] = [:]
        let appRef: (Int32) -> AppRef? = { pid in
            if let known = cache[pid] { return known }
            let ref = Self.appRef(forPID: pid)
            cache[pid] = ref
            return ref
        }

        let scanned = assemble(displays: displays, skyLight: skyLight, catalog: catalog,
                               activeSpaceID: SpaceReader.activeSpaceID(), appRef: appRef, ax: ax, options: options,
                               accessibilityTrusted: trusted, screenIsLocked: locked, notes: notes)
        return StageManager.annotate(scanned)
    }

    /// True while the login window or screen saver covers the session.
    public static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private static func appRef(forPID pid: Int32) -> AppRef? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        guard let name = app.localizedName ?? app.bundleIdentifier else { return nil }
        return AppRef(bundleID: app.bundleIdentifier, name: name, path: app.bundleURL?.path)
    }

    // MARK: Accessibility

    /// Processes worth asking Accessibility about: regular apps with a window that could be a user window,
    /// either on a Space or (for minimized ones) on no Space.
    private static func accessibilityCandidates(catalog: [CatalogWindow], options: ScanOptions) -> Set<Int32> {
        var pids = Set<Int32>()
        // Small windows count too: the window server reports tiny bounds for a real window on another Space.
        for window in catalog where window.alpha > 0.01 && (!window.spaceIDs.isEmpty
            || min(window.bounds.width, window.bounds.height) >= 100) {
            guard !pids.contains(window.pid),
                  let app = NSRunningApplication(processIdentifier: window.pid),
                  app.activationPolicy == .regular,
                  !isExcludedApp(name: window.appName, bundleID: app.bundleIdentifier, options: options) else { continue }
            pids.insert(window.pid)
        }
        return pids
    }

    /// Title, document and minimized state of every window Accessibility lists, by CGWindowID.
    private static func readAccessibility(pids: Set<Int32>) -> [UInt32: AXWindowDetails] {
        var result: [UInt32: AXWindowDetails] = [:]
        for pid in pids {
            for element in AXWindows.windows(ofPID: pid) {
                guard let windowID = element.windowID else { continue }
                let title = element.title.flatMap { $0.isEmpty ? nil : $0 }
                result[windowID] = AXWindowDetails(title: title, documentPath: AXWindows.documentPath(of: element),
                                                   isMinimized: element.isMinimized, frame: element.frame)
            }
            // Windows on another Space are not in AXWindows; the app still hands them out directly.
            for (windowID, element) in AXRemoteWindows.directWindows(pid: pid) where result[windowID] == nil {
                let title = element.title.flatMap { $0.isEmpty ? nil : $0 }
                result[windowID] = AXWindowDetails(title: title, documentPath: AXWindows.documentPath(of: element),
                                                   isMinimized: element.isMinimized, frame: element.frame)
            }
        }
        return result
    }

    // MARK: Filter (pure)

    /// True for apps whose windows are never part of a workspace: Windows Manager, Dock, Window Server,
    /// Control Center, SystemUIServer, Notification Center, Stage Manager ("WindowManager"), and every bundle
    /// id in `options.excludedBundleIDs`.
    public static func isExcludedApp(name: String, bundleID: String?, options: ScanOptions = ScanOptions()) -> Bool {
        if excludedAppNames.contains(name.lowercased()) { return true }
        guard let bundleID else { return false }
        let id = bundleID.lowercased()
        return excludedBundleIDs.contains(id) || options.excludedBundleIDs.contains { $0.lowercased() == id }
    }

    /// The scanner's window filter: a normal window (layer 0, as `WindowCatalog` lists) that
    /// `CatalogWindow.looksLikeUserWindow` accepts and that belongs to an app that is not excluded.
    /// A minimized window belongs to no Space, so it passes too when Accessibility says it is minimized
    /// (`isMinimized`) and it is big and visible enough.
    ///
    /// A window the window server reports as small is still kept when it is on a Space, visible, and
    /// Accessibility gives it a real frame (`axFrame`) that is big enough: the small bounds are then a thumbnail
    /// of a window on an inactive Space or in the Stage Manager strip. Without such a frame it stays out.
    public static func isUserWindow(_ window: CatalogWindow, bundleID: String?, isMinimized: Bool = false,
                                    axFrame: CGRect? = nil, options: ScanOptions = ScanOptions()) -> Bool {
        if isExcludedApp(name: window.appName, bundleID: bundleID, options: options) { return false }
        if window.looksLikeUserWindow { return true }
        if usesAccessibilityFrame(window, axFrame: axFrame) { return true }
        return isMinimized && window.spaceIDs.isEmpty && window.alpha > 0.01
            && min(window.bounds.width, window.bounds.height) >= 100
    }

    /// True when the window server's bounds are too small only because of a thumbnail (window on an inactive
    /// Space or in the Stage Manager strip) and Accessibility shows a real, user-sized frame.
    static func usesAccessibilityFrame(_ window: CatalogWindow, axFrame: CGRect?) -> Bool {
        guard let axFrame, !window.spaceIDs.isEmpty, window.alpha > 0.01, window.appName != "WindowManager",
              min(window.bounds.width, window.bounds.height) < 100 else { return false }
        return min(axFrame.width, axFrame.height) >= 100
    }

    /// For each full-screen Space, the window(s) that own it, as CGWindowIDs: one normally, two for Split View.
    /// The ids come from SkyLight (`fullScreenWindowIDs`) when those windows are in `windows`. When none of them
    /// is, the biggest window on that Space (of the owner process when SkyLight names one) stands in.
    /// Spaces without any owner are missing from the result.
    public static func fullScreenOwners(spaces: [SpaceInfo], windows: [CatalogWindow]) -> [UInt64: [UInt32]] {
        var owners: [UInt64: [UInt32]] = [:]
        for space in spaces where space.kind == .fullscreen {
            let known = space.fullScreenWindowIDs.filter { id in windows.contains { $0.windowID == id } }
            if !known.isEmpty {
                owners[space.id] = known
                continue
            }
            let onSpace = windows.filter { window in
                window.spaceIDs.contains(space.id) && (space.fullScreenOwnerPID.map { $0 == window.pid } ?? true)
            }
            if let biggest = onSpace.max(by: { area($0.bounds) < area($1.bounds) }) {
                owners[space.id] = [biggest.windowID]
            }
        }
        return owners
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    /// The monitor SkyLight means by `identifier`: its UUID (case-insensitive), or "Main" for the main display.
    static func resolveDisplay(_ identifier: String, in displays: [DisplayIdentity]) -> DisplayIdentity? {
        if let match = displays.first(where: { $0.uuid.caseInsensitiveCompare(identifier) == .orderedSame }) {
            return match
        }
        return identifier == "Main" ? displays.first(where: \.isMain) : nil
    }

    /// A key that is the same for all windows of one app: the bundle id, else the name.
    private static func appKey(_ app: AppRef) -> String {
        app.bundleID.map { "id:\($0)" } ?? "name:\(app.name.lowercased())"
    }

    // MARK: Assemble (pure)

    /// Builds a scan from raw readings. Nothing here touches the system.
    /// - `catalog` must be in front-to-back order, as `WindowCatalog.all()` returns it.
    /// - `ax` holds what Accessibility said about windows, by CGWindowID (empty when it was not read).
    static func assemble(displays: [DisplayIdentity], skyLight: [DisplaySpaces], catalog: [CatalogWindow],
                         activeSpaceID: UInt64, appRef: (Int32) -> AppRef?, ax: [UInt32: AXWindowDetails],
                         options: ScanOptions = ScanOptions(), accessibilityTrusted: Bool = true,
                         screenIsLocked: Bool = false, notes: [String] = [],
                         scannedAt: Date = Date()) -> WorkspaceScan {
        var notes = notes

        // Spaces per monitor, in the order of `displays`.
        var scanned: [ScannedSpaces] = []
        for entry in skyLight {
            guard let display = resolveDisplay(entry.displayIdentifier, in: displays) else {
                notes.append("SkyLight lists Spaces for display \(entry.displayIdentifier), which is not a connected screen; they were left out.")
                continue
            }
            if scanned.contains(where: { $0.displayUUID == display.uuid }) {
                notes.append("SkyLight lists display \(display.name) more than once; the first list was used.")
                continue
            }
            scanned.append(ScannedSpaces(displayUUID: display.uuid, skyLightIdentifier: entry.displayIdentifier,
                                         currentSpaceID: entry.currentSpaceID, spaces: entry.spaces))
        }
        scanned.sort { a, b in
            (displays.firstIndex { $0.uuid == a.displayUUID } ?? Int.max)
                < (displays.firstIndex { $0.uuid == b.displayUUID } ?? Int.max)
        }

        let allSpaces = scanned.flatMap(\.spaces)
        let fullScreenSpaceIDs = Set(allSpaces.filter { $0.kind == .fullscreen }.map(\.id))
        let currentSpaceIDs = Set(scanned.map(\.currentSpaceID))

        // Which catalog windows are user windows.
        var accepted: [(window: CatalogWindow, app: AppRef?)] = []
        for window in catalog {
            let app = appRef(window.pid)
            if isUserWindow(window, bundleID: app?.bundleID, isMinimized: ax[window.windowID]?.isMinimized ?? false,
                            axFrame: ax[window.windowID]?.frame, options: options) {
                accepted.append((window, app))
            }
        }

        // Owners of full-screen Spaces; windows that only sit on a full-screen Space without owning it
        // are overlays (toolbars, menu bar strips).
        let owners = fullScreenOwners(spaces: allSpaces, windows: accepted.map(\.window))
        let ownerIDs = Set(owners.values.flatMap { $0 })
        if !options.includeFullScreenHelperWindows {
            accepted.removeAll { entry in
                let ids = entry.window.spaceIDs
                return !ids.isEmpty && ids.allSatisfy(fullScreenSpaceIDs.contains)
                    && !ownerIDs.contains(entry.window.windowID)
            }
        }

        var indexInApp: [String: Int] = [:]
        var windows: [LiveWindow] = []
        for (window, app) in accepted {
            let appRef = app ?? AppRef(bundleID: nil, name: window.appName)
            let index = indexInApp[appKey(appRef), default: 0]
            indexInApp[appKey(appRef)] = index + 1
            let details = ax[window.windowID]
            let frame = usesAccessibilityFrame(window, axFrame: details?.frame) ? details!.frame! : window.bounds
            windows.append(LiveWindow(
                windowID: window.windowID, pid: window.pid, app: appRef,
                title: window.title ?? details?.title, documentPath: details?.documentPath,
                frame: frame,
                displayUUID: DisplayMap.display(containing: frame, in: displays)?.uuid,
                spaceIDs: window.spaceIDs, isFullScreen: ownerIDs.contains(window.windowID),
                isMinimized: details?.isMinimized ?? false, indexInApp: index,
                isOnCurrentSpace: !currentSpaceIDs.isDisjoint(with: window.spaceIDs)))
        }

        return WorkspaceScan(displays: displays, spaces: scanned, windows: windows, activeSpaceID: activeSpaceID,
                             accessibilityTrusted: accessibilityTrusted, screenIsLocked: screenIsLocked,
                             notes: notes, scannedAt: scannedAt)
    }

    // MARK: Placement (pure)

    /// Where `window` lives in Mission Control, among the Spaces of the monitor it is on:
    ///  - `.fullScreen(position:)` when it is on (or owns) a full-screen Space, 0-based position among all
    ///    Spaces of that monitor;
    ///  - `.allDesktops` when it is on every Desktop of its monitor (and the monitor has more than one);
    ///  - `.desktop(number:)` for the first Desktop it is on;
    ///  - `.unknown` when it is on no Space (minimized), or its Space is not one of its monitor's Spaces.
    public static func placement(for window: LiveWindow, in scan: WorkspaceScan) -> SpacePlacement {
        let lists: [ScannedSpaces]
        if let uuid = window.displayUUID {
            lists = scan.spaces(onDisplay: uuid).map { [$0] } ?? []
        } else {
            lists = scan.spaces
        }

        for list in lists {
            if let space = list.fullScreenSpaces.first(where: { window.spaceIDs.contains($0.id) })
                ?? list.fullScreenSpaces.first(where: { $0.fullScreenWindowIDs.contains(window.windowID) }) {
                return .fullScreen(position: space.index)
            }
        }
        for list in lists {
            let desktops = list.desktops
            let on = desktops.filter { window.spaceIDs.contains($0.id) }
            guard let first = on.first else { continue }
            if desktops.count > 1 && on.count == desktops.count { return .allDesktops }
            return .desktop(number: list.desktopNumber(of: first) ?? 1)
        }
        return .unknown
    }
}
