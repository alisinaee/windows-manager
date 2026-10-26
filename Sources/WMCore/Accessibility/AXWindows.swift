import AppKit
import ApplicationServices

/// One window as seen through the Accessibility API.
public struct WindowInfo: Codable, Equatable {
    public var pid: Int32
    public var appName: String
    public var bundleID: String?
    /// CGWindowID; 0 when it could not be read.
    public var windowID: UInt32
    public var title: String
    /// Frame in global screen coordinates (origin top-left of the main display).
    public var frame: CGRect
    public var isFullScreen: Bool
    public var isMinimized: Bool

    public init(pid: Int32, appName: String, bundleID: String?, windowID: UInt32, title: String,
                frame: CGRect, isFullScreen: Bool, isMinimized: Bool) {
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
        self.windowID = windowID
        self.title = title
        self.frame = frame
        self.isFullScreen = isFullScreen
        self.isMinimized = isMinimized
    }
}

/// Small helper around the Accessibility API for finding apps and reading / changing their windows.
/// All calls need Accessibility permission (see `AXPermission`); without it reads return empty values.
public enum AXWindows {
    private static let fullScreenAttribute = "AXFullScreen"

    // MARK: Finding apps

    /// Running apps whose name or bundle id equals `query` (case-insensitive).
    /// If nothing matches exactly, apps whose name or bundle id contains `query` are returned.
    public static func runningApps(matching query: String) -> [NSRunningApplication] {
        let q = query.lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let exact = apps.filter {
            $0.localizedName?.lowercased() == q || $0.bundleIdentifier?.lowercased() == q
        }
        if !exact.isEmpty { return exact }
        return apps.filter {
            ($0.localizedName?.lowercased().contains(q) ?? false)
                || ($0.bundleIdentifier?.lowercased().contains(q) ?? false)
        }
    }

    // MARK: Listing windows

    /// AX window elements of an app (includes minimized and full-screen windows of the app).
    public static func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 2.0)
        guard let value = copy(element, kAXWindowsAttribute) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    /// Full description of one window of `app`.
    public static func info(of window: AXUIElement, app: NSRunningApplication) -> WindowInfo {
        WindowInfo(
            pid: app.processIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            bundleID: app.bundleIdentifier,
            windowID: windowID(of: window) ?? 0,
            title: title(of: window),
            frame: frame(of: window) ?? .zero,
            isFullScreen: isFullScreen(window),
            isMinimized: isMinimized(window)
        )
    }

    /// Every window of every running app matching `query` (name or bundle id).
    public static func windowInfos(matching query: String) -> [WindowInfo] {
        runningApps(matching: query).flatMap { app in
            windows(of: app).map { info(of: $0, app: app) }
        }
    }

    // MARK: Reading attributes

    public static func title(of window: AXUIElement) -> String {
        (copy(window, kAXTitleAttribute) as? String) ?? ""
    }

    public static func position(of window: AXUIElement) -> CGPoint? {
        guard let value = copy(window, kAXPositionAttribute), isAXValue(value) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point) else { return nil }
        return point
    }

    public static func size(of window: AXUIElement) -> CGSize? {
        guard let value = copy(window, kAXSizeAttribute), isAXValue(value) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size) else { return nil }
        return size
    }

    public static func frame(of window: AXUIElement) -> CGRect? {
        guard let origin = position(of: window), let size = size(of: window) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    public static func isFullScreen(_ window: AXUIElement) -> Bool {
        boolAttribute(window, fullScreenAttribute)
    }

    public static func isMinimized(_ window: AXUIElement) -> Bool {
        boolAttribute(window, kAXMinimizedAttribute)
    }

    /// CGWindowID of an AX window (private `_AXUIElementGetWindow`, see `AXElement.windowID`), or nil on failure.
    public static func windowID(of window: AXUIElement) -> CGWindowID? {
        AXElement(window, timeout: nil).windowID
    }

    // MARK: Changing windows

    @discardableResult
    public static func setSize(_ size: CGSize, of window: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    @discardableResult
    public static func setPosition(_ point: CGPoint, of window: AXUIElement) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    /// Sets size, then position, then size again. The first size lets the window fit on the target
    /// screen, the last one fixes windows that were clamped while moving between screens.
    /// Simple unchecked version (no read-back, no retry). The app uses `WindowMover.setFrame`, which also
    /// verifies the result; this one stays for the Spaces Lab commands.
    @discardableResult
    public static func setFrame(_ frame: CGRect, of window: AXUIElement) -> Bool {
        let first = setSize(frame.size, of: window)
        let moved = setPosition(frame.origin, of: window)
        let last = setSize(frame.size, of: window)
        return first && moved && last
    }

    @discardableResult
    public static func setFullScreen(_ on: Bool, for window: AXUIElement) -> Bool {
        let value: CFBoolean = on ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(window, fullScreenAttribute as CFString, value) == .success
    }

    @discardableResult
    public static func raise(_ window: AXUIElement) -> Bool {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    // MARK: AXElement based API (used by the app)

    private static let documentAttribute = kAXDocumentAttribute
    private static let standardWindowSubrole = kAXStandardWindowSubrole

    /// Windows of a process that AX lists, as `AXElement`s (1 s messaging timeout).
    /// Important: AX only lists windows on the Space(s) that are visible right now, plus minimized
    /// windows. Windows on other Spaces appear after the person switches there. Elements obtained earlier
    /// stay usable after their Space is left.
    /// Only elements with role AXWindow are returned: for windows of other Spaces macOS can list
    /// placeholder entries (role AXApplication, no frame, no title) that cannot be used for anything.
    public static func windows(ofPID pid: pid_t) -> [AXElement] {
        AXElement.application(pid: pid).elements(kAXWindowsAttribute).filter { $0.role == kAXWindowRole }
    }

    /// Only windows with role AXWindow and subrole AXStandardWindow: no dialogs, sheets, palettes or
    /// system overlays. Most apps' ordinary windows qualify; a few that do not set a subrole are skipped.
    public static func standardWindows(ofPID pid: pid_t) -> [AXElement] {
        AXElement.application(pid: pid).elements(kAXWindowsAttribute).filter(isStandardWindow)
    }

    /// The app's main window (AXMainWindow), if any.
    public static func mainWindow(ofPID pid: pid_t) -> AXElement? {
        AXElement.application(pid: pid).element(kAXMainWindowAttribute)
    }

    /// The app's focused window (AXFocusedWindow), if any.
    public static func focusedWindow(ofPID pid: pid_t) -> AXElement? {
        AXElement.application(pid: pid).element(kAXFocusedWindowAttribute)
    }

    /// The focused window of the frontmost app.
    public static func focusedWindow() -> AXElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return focusedWindow(ofPID: app.processIdentifier)
    }

    /// True for a window with role AXWindow and subrole AXStandardWindow.
    public static func isStandardWindow(_ window: AXElement) -> Bool {
        window.role == kAXWindowRole && window.subrole == standardWindowSubrole
    }

    /// File URL of the document shown in the window (AXDocument), nil for windows without a file.
    public static func documentURL(of window: AXElement) -> URL? {
        guard let text = window.string(documentAttribute), !text.isEmpty else { return nil }
        if let url = URL(string: text), url.isFileURL { return url }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        return nil
    }

    /// Path of the document shown in the window (AXDocument), nil for windows without a file.
    public static func documentPath(of window: AXElement) -> String? {
        documentURL(of: window)?.path
    }

    /// Full description of one window of `app`.
    public static func info(of window: AXElement, app: NSRunningApplication) -> WindowInfo {
        info(of: window.raw, app: app)
    }

    // MARK: Helpers

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func isAXValue(_ value: CFTypeRef) -> Bool {
        CFGetTypeID(value) == AXValueGetTypeID()
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        guard let value = copy(element, attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }
}
