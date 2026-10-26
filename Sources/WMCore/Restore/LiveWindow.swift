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

    public var id: UInt32 { windowID }

    public init(windowID: UInt32, pid: Int32 = 0, app: AppRef, title: String? = nil, documentPath: String? = nil,
                frame: CGRect, displayUUID: String? = nil, spaceIDs: [UInt64] = [], isFullScreen: Bool = false,
                isMinimized: Bool = false, indexInApp: Int = 0, isOnCurrentSpace: Bool = true,
                isInStageStrip: Bool = false) {
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
    }
}
