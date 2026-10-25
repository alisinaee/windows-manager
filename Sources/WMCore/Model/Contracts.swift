import CoreGraphics
import Foundation

// Shared types for the app (phase P2). Every saved frame uses global top-left coordinates,
// the same space the Accessibility API and CGWindowList use (origin at the top-left of the main display).

/// A stable description of a monitor. Saved in profiles and matched against live displays (DisplayMap, P2.3).
public struct DisplayIdentity: Codable, Hashable, Sendable {
    /// CGDisplayCreateUUIDFromDisplayID, the most stable key across reboots.
    public var uuid: String
    /// NSScreen.localizedName, for people.
    public var name: String
    public var vendorID: UInt32
    public var modelID: UInt32
    public var serial: UInt32
    /// Whole display, global top-left coordinates.
    public var frame: CGRect
    /// Display without menu bar and Dock, global top-left coordinates.
    public var visibleFrame: CGRect
    public var isMain: Bool
    public var isBuiltIn: Bool
    public var scale: Double

    public init(uuid: String, name: String, vendorID: UInt32 = 0, modelID: UInt32 = 0, serial: UInt32 = 0,
                frame: CGRect, visibleFrame: CGRect, isMain: Bool, isBuiltIn: Bool, scale: Double = 2) {
        self.uuid = uuid
        self.name = name
        self.vendorID = vendorID
        self.modelID = modelID
        self.serial = serial
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
        self.scale = scale
    }
}

/// An app as saved in a profile.
public struct AppRef: Codable, Hashable, Sendable {
    public var bundleID: String?
    public var name: String
    /// Path of the .app bundle when it was captured, used to launch it if the bundle id is missing.
    public var path: String?

    public init(bundleID: String?, name: String, path: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}

/// Where a window lives in Mission Control, per display.
public enum SpacePlacement: Codable, Hashable, Sendable {
    /// A normal Desktop, 1-based number among the Desktops of its display.
    case desktop(number: Int)
    /// A native full-screen Space, 0-based position among all Spaces of its display (Mission Control order).
    case fullScreen(position: Int)
    /// "Assign to all Desktops" windows.
    case allDesktops
    case unknown
}
