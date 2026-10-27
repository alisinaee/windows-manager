import CoreGraphics
import Foundation

/// A window that exists right now, as the window matcher (`WindowMatcher`) sees it. Plain data only:
/// the restore engine (P2.5) builds these from `WindowCatalog` (window server) and the Accessibility API.
/// The frame uses global top-left coordinates, like every saved frame (see Contracts.swift).
public struct LiveWindow: Hashable, Sendable, Identifiable {
    /// CGWindowID.
    public var windowID: UInt32
    public var pid: Int32
    public var app: AppRef
    /// Nil when neither Screen Recording nor Accessibility can tell the title.
    public var title: String?
    /// Document path or file URL (AXDocument) when the app exposes one.
    public var documentPath: String?
    /// Global top-left coordinates.
    public var frame: CGRect
    /// `DisplayIdentity.uuid` of the display the window is on, nil when unknown.
    public var displayUUID: String?
    /// Ids of the Spaces the window is on.
    public var spaceIDs: [UInt64]
    public var isFullScreen: Bool
    public var isMinimized: Bool
    /// Position among this app's windows, front to back (0 = frontmost).
    public var indexInApp: Int
    /// True when the window sits on a Space that is visible right now (so Accessibility can reach it).
    public var isOnCurrentSpace: Bool
    /// Stage Manager is on and the window sits in the strip or in another stage, where it cannot be moved.
    public var isInStageStrip: Bool
    /// CGWindowList `kCGWindowIsOnscreen`; nil when not known (hand-built windows).
    public var isOnScreen: Bool?
    /// The owning app is hidden (Cmd-H), which also makes its windows not on screen.
    public var isAppHidden: Bool
    /// True for the small thumbnail Stage Manager draws in its strip: a real window of the app, on screen, with
    /// thumbnail-sized bounds at a display edge. It is not a window the person has in the active stage.
    public var isStripThumbnail: Bool
    /// Stage Manager placement worked out by `StageManager.annotate`; nil when Stage Manager is off or unknown.
    public var stage: SavedStage?
    /// Window-server (CGWindowList) bounds, as the window server draws the window now. They are thumbnail-sized for a
    /// Stage Manager strip thumbnail and for a window on another Space; `frame` stays the Accessibility frame.
    /// Nil when not known (hand-built windows).
    public var serverBounds: CGRect?

    public var id: UInt32 { windowID }

    public init(windowID: UInt32, pid: Int32 = 0, app: AppRef, title: String? = nil, documentPath: String? = nil,
                frame: CGRect, displayUUID: String? = nil, spaceIDs: [UInt64] = [], isFullScreen: Bool = false,
                isMinimized: Bool = false, indexInApp: Int = 0, isOnCurrentSpace: Bool = true,
                isInStageStrip: Bool = false, isOnScreen: Bool? = nil, isAppHidden: Bool = false,
                isStripThumbnail: Bool = false, stage: SavedStage? = nil, serverBounds: CGRect? = nil) {
        self.windowID = windowID
        self.pid = pid
        self.app = app
        self.title = title
        self.documentPath = documentPath
        self.frame = frame
        self.displayUUID = displayUUID
        self.spaceIDs = spaceIDs
        self.isFullScreen = isFullScreen
        self.isMinimized = isMinimized
        self.indexInApp = indexInApp
        self.isOnCurrentSpace = isOnCurrentSpace
        self.isInStageStrip = isInStageStrip
        self.isOnScreen = isOnScreen
        self.isAppHidden = isAppHidden
        self.isStripThumbnail = isStripThumbnail
        self.stage = stage
        self.serverBounds = serverBounds
    }
}
