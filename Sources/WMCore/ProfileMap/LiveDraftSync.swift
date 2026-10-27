import CoreGraphics
import Foundation

// Keeps a Builder draft in step with the real workspace while Live is on (P6.67). Pure: the app scans and calls
// `merge`. The draft keeps what only the user decides (name, icon, options, launch plan, planned windows and every
// window the user edited by hand); the desktop facts come from the scan (frames, monitors, Spaces, Stage Manager).

public enum LiveDraftSync {
    /// What one merge did, for the debug log and the caller.
    public struct Outcome: Equatable, Sendable {
        public var profile: Profile
        /// Windows the scan found that the draft did not have.
        public var added: Int
        /// Draft windows whose app is gone (closed), removed.
        public var removed: Int
        /// Draft windows whose frame, Space, stage or title came from the scan.
        public var updated: Int
        /// Dismissed windows (deleted by the user) that the scan still sees; the others are no longer needed.
        public var stillDismissed: [WindowSnapshot]

        public var changed: Bool { added + removed + updated > 0 }
    }

    /// The merged draft (see `outcome`).
    public static func merge(draft: Profile, scanned: Profile, manuallyEdited: Set<UUID> = [],
                             dismissed: [WindowSnapshot] = []) -> Profile {
        outcome(draft: draft, scanned: scanned, manuallyEdited: manuallyEdited, dismissed: dismissed).profile
    }

    /// Merges a fresh scan (`scanned`, built by `ProfileCapture.makeProfile`) into `draft`.
    ///
    /// Windows are matched by app (bundle id or name), preferring the same title, then the nearest frame; each scanned
    /// window is used once. A draft window with no scanned partner is removed unless the user edited it or it was
    /// planned by hand. A scanned window with no draft partner is added, unless it matches a `dismissed` window (one the
    /// user deleted while the app was still open). `manuallyEdited` draft windows keep their values.
    public static func outcome(draft: Profile, scanned: Profile, manuallyEdited: Set<UUID> = [],
                               dismissed: [WindowSnapshot] = []) -> Outcome {
        // 1. Deleted windows the scan still sees are skipped, so they do not come back.
        var remaining = scanned.windows
        var stillDismissed: [WindowSnapshot] = []
        for gone in dismissed {
            guard let i = remaining.firstIndex(where: { sameWindow($0, gone) }) else { continue }
            remaining.remove(at: i)
            stillDismissed.append(gone)
        }

        // 2. Match draft windows to scanned ones, closest pairs first (same title beats a different one).
        struct Pair { let draft: Int; let scan: Int; let titleDiffers: Int; let distance: CGFloat }
        var pairs: [Pair] = []
        for (d, window) in draft.windows.enumerated() {
            for (s, live) in remaining.enumerated() where Profile.isSameApp(window.app, live.app) {
                pairs.append(Pair(draft: d, scan: s, titleDiffers: window.title == live.title ? 0 : 1,
                                  distance: frameDistance(window.frame, live.frame)))
            }
        }
        pairs.sort { ($0.titleDiffers, $0.distance, $0.draft, $0.scan) < ($1.titleDiffers, $1.distance, $1.draft, $1.scan) }
        var scanForDraft: [Int: Int] = [:]
        var usedScan = Set<Int>()
        for pair in pairs where scanForDraft[pair.draft] == nil && !usedScan.contains(pair.scan) {
            scanForDraft[pair.draft] = pair.scan
            usedScan.insert(pair.scan)
        }

        // 3. Rebuild the windows in draft order, then append the new ones in scan order.
        var result = draft
        var windows: [WindowSnapshot] = []
        var idForScanned: [UUID: UUID] = [:]
        var added = 0, removed = 0, updated = 0
        for (d, window) in draft.windows.enumerated() {
            let protected = manuallyEdited.contains(window.id) || window.origin == .planned
            guard let s = scanForDraft[d] else {
                if protected { windows.append(window) } else { removed += 1 }
                continue
            }
            idForScanned[remaining[s].id] = window.id
            if protected {
                windows.append(window)
                continue
            }
            let refreshed = refreshed(window, from: remaining[s])
            if refreshed != window { updated += 1 }
            windows.append(refreshed)
        }
        for (s, live) in remaining.enumerated() where !usedScan.contains(s) {
            windows.append(live)
            idForScanned[live.id] = live.id
            added += 1
        }

        // 4. Monitors, Spaces and Stage Manager come from the scan. Full-screen Spaces point at the kept ids.
        result.windows = windows
        if !scanned.displays.isEmpty {
            result.displays = scanned.displays
            result.monitorSetKey = scanned.monitorSetKey
        }
        if !scanned.spaces.isEmpty {
            result.spaces = scanned.spaces.map { space in
                var s = space
                s.fullScreenWindowIDs = space.fullScreenWindowIDs.compactMap { idForScanned[$0] }
                return s
            }
        }
        result.stageManagerOn = scanned.stageManagerOn ?? draft.stageManagerOn

        return Outcome(profile: result, added: added, removed: removed, updated: updated,
                       stillDismissed: stillDismissed)
    }

    // MARK: Helpers

    /// The draft window with the live facts of its scanned partner. Title, document path and stage are taken from the
    /// scan when it has them. A window that moved loses its zone name (the zone no longer describes it).
    private static func refreshed(_ window: WindowSnapshot, from live: WindowSnapshot) -> WindowSnapshot {
        var u = window
        u.title = live.title ?? window.title
        u.documentPath = live.documentPath ?? window.documentPath
        u.indexInApp = live.indexInApp
        u.displayUUID = live.displayUUID
        u.frame = live.frame
        u.relativeFrame = live.relativeFrame
        u.placement = live.placement
        u.isFullScreen = live.isFullScreen
        u.isMinimized = live.isMinimized
        u.zIndex = live.zIndex
        u.stage = live.stage ?? window.stage   // the scan cannot see windows on another Desktop: keep what we knew
        if live.frame != window.frame || live.displayUUID != window.displayUUID { u.zoneName = nil }
        return u
    }

    /// Same app, same title, and a frame within a few points: the scan's view of a window the user deleted.
    private static func sameWindow(_ live: WindowSnapshot, _ gone: WindowSnapshot) -> Bool {
        Profile.isSameApp(live.app, gone.app) && live.title == gone.title && frameDistance(live.frame, gone.frame) <= 4
    }

    /// Sum of the differences of origin and size: 0 for the same frame, larger the further apart.
    private static func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}
