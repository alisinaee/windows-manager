import CoreGraphics
import Foundation

// Turns a `WorkspaceScan` into a `Profile` (phase P2.5). `makeProfile` is pure, so it is tested with fixture
// scans; `capture(name:)` is the one call that reads the real workspace first.

public enum ProfileCapture {
    /// Scans the workspace now and builds a profile from it. The strings are warnings for people.
    public static func capture(name: String, options: ProfileOptions = ProfileOptions(),
                               scanOptions: ScanOptions = ScanOptions()) -> (Profile, [String]) {
        makeProfile(name: name, from: WorkspaceScanner.scan(options: scanOptions), options: options)
    }

    /// Builds a profile from a scan: monitors, the Spaces of every monitor in order (a full-screen Space points at
    /// the snapshot ids of the window(s) that own it) and one snapshot per window.
    ///
    /// Each window gets: its frame and `relativeFrame` (fractions of its monitor's visible frame, not clamped;
    /// a window that owns a full-screen Space always gets 0,0,1,1 because it fills the screen), its `placement`, `zIndex` = position in `scan.windows` (0 = front, counting only captured windows),
    /// `titleMatch` `.any` and `restore` true.
    ///
    /// The second value lists what a person should check: windows without a title, apps without a bundle id,
    /// full-screen Spaces whose owner window was not found, windows with an unknown placement, and the scan's
    /// own notes (screen locked, ...). A profile is returned even when there are warnings.
    ///
    /// `now` and `makeID` exist so tests can get fixed dates and ids.
    public static func makeProfile(name: String, from scan: WorkspaceScan, options: ProfileOptions = ProfileOptions(),
                                   now: Date = Date(), makeID: () -> UUID = { UUID() }) -> (Profile, [String]) {
        var warnings = scan.notes
        var snapshots: [WindowSnapshot] = []
        var snapshotID: [UInt32: UUID] = [:]
        var appsWithoutBundleID = Set<String>()

        for window in scan.windows {
            guard let display = display(of: window, in: scan) else {
                warnings.append("\(describe(window)) was left out: no display is known to put it on.")
                continue
            }
            let placement = WorkspaceScanner.placement(for: window, in: scan)
            let id = makeID()
            snapshotID[window.windowID] = id
            snapshots.append(WindowSnapshot(
                id: id, app: window.app, title: window.title, titleMatch: .any, documentPath: window.documentPath,
                indexInApp: window.indexInApp, displayUUID: display.uuid, frame: window.frame,
                relativeFrame: window.isFullScreen ? CGRect(x: 0, y: 0, width: 1, height: 1)
                    : relativeFrame(of: window.frame, in: display),
                placement: placement,
                isFullScreen: window.isFullScreen, isMinimized: window.isMinimized, zIndex: snapshots.count,
                restore: true))

            if window.title == nil {
                warnings.append("\(describe(window)) has no title (Screen Recording or Accessibility access may be missing); it is matched by app and position only.")
            }
            if window.app.bundleID == nil, appsWithoutBundleID.insert(window.app.name.lowercased()).inserted {
                warnings.append("\(window.app.name) has no bundle id; a restore can only find it by name.")
            }
            if placement == .unknown {
                warnings.append("\(describe(window)) has an unknown placement: "
                    + (window.isMinimized ? "it is minimized and belongs to no Space." : "its Space is not one of its display's Spaces."))
            }
        }

        if scan.stageManagerOn == true {
            let parked = scan.windows.filter(\.isInStageStrip).count
            if parked > 0 {
                warnings.append("Stage Manager is on: \(parked) window\(parked == 1 ? " sits" : "s sit") in the strip or another stage; "
                    + "\(parked == 1 ? "its" : "their") position is saved as it is now and may not be exact.")
            }
        }

        // Spaces, with the owner windows of full-screen Spaces.
        var spaces: [SpaceSnapshot] = []
        for list in scan.spaces {
            let displayName = scan.display(withUUID: list.displayUUID)?.name ?? list.displayUUID
            for space in list.spaces {
                var ownerIDs: [UUID] = []
                if space.kind == .fullscreen {
                    let owners = fullScreenOwners(of: space, in: scan)
                    ownerIDs = owners.compactMap { snapshotID[$0.windowID] }
                    let label = "Space \(space.index + 1) of \(displayName) (full screen: \(space.ownerAppNames.isEmpty ? "unknown app" : space.ownerAppNames.joined(separator: " + ")))"
                    if ownerIDs.isEmpty {
                        warnings.append("\(label) has no owner window in the scan, so it cannot be restored.")
                    } else if ownerIDs.count < space.fullScreenWindowIDs.count {
                        warnings.append("\(label) lists \(space.fullScreenWindowIDs.count) windows but only \(ownerIDs.count) were found.")
                    }
                }
                spaces.append(SpaceSnapshot(
                    displayUUID: list.displayUUID, position: space.index, kind: SavedSpaceKind(space.kind),
                    desktopNumber: list.desktopNumber(of: space), fullScreenWindowIDs: ownerIDs))
            }
        }

        let profile = Profile(id: makeID(), name: name, createdAt: now, monitorSetKey: DisplayMap.monitorSetKey(scan.displays),
                              displays: scan.displays, spaces: spaces, windows: snapshots, options: options,
                              stageManagerOn: scan.stageManagerOn)
        return (profile, warnings)
    }

    // MARK: Helpers

    /// `frame` as fractions of the display's `visibleFrame` (its whole frame when the visible frame is empty).
    /// Windows that stick out of the display give values below 0 or above 1; nothing is clamped.
    public static func relativeFrame(of frame: CGRect, in display: DisplayIdentity) -> CGRect {
        var area = display.visibleFrame
        if area.width <= 0 || area.height <= 0 { area = display.frame }
        guard area.width > 0, area.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: (frame.minX - area.minX) / area.width, y: (frame.minY - area.minY) / area.height,
                      width: frame.width / area.width, height: frame.height / area.height)
    }

    /// The display a window is saved on: the one the scanner found, else the one holding most of its frame.
    private static func display(of window: LiveWindow, in scan: WorkspaceScan) -> DisplayIdentity? {
        if let uuid = window.displayUUID, let display = scan.display(withUUID: uuid) { return display }
        return DisplayMap.display(containing: window.frame, in: scan.displays)
    }

    /// The window(s) that own a full-screen Space: the windows SkyLight names; else the full-screen windows
    /// that sit on the Space.
    private static func fullScreenOwners(of space: SpaceInfo, in scan: WorkspaceScan) -> [LiveWindow] {
        let named = scan.windows.filter { space.fullScreenWindowIDs.contains($0.windowID) }
        if !named.isEmpty { return named }
        return scan.windows.filter { $0.isFullScreen && $0.spaceIDs.contains(space.id) }
    }

    /// `Google Chrome "Inbox" (window 84)`, for warnings.
    private static func describe(_ window: LiveWindow) -> String {
        let title = window.title.map { " \"\($0)\"" } ?? ""
        return "\(window.app.name)\(title) (window \(window.windowID))"
    }
}
