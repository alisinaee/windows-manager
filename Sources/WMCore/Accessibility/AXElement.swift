import ApplicationServices
import CoreGraphics
import Foundation

// Private but long-stable call: maps an AX window element to its CGWindowID.
// (Moved here from AXWindows.swift; `AXElement.windowID` and `AXWindows.windowID(of:)` both use it.)
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

public extension AXError {
    var isSuccess: Bool { self == .success }

    /// Readable name for logs and reports, for example "cannotComplete".
    var symbolicName: String {
        switch self {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "AXError(\(rawValue))"
        }
    }
}

/// Thin typed wrapper over `AXUIElement`: attribute reads and writes (String, Bool, CGPoint, CGSize, CGRect,
/// elements), actions, pid and CGWindowID.
///
/// Every wrapper gets a messaging timeout (default 1 second) so one hung app cannot block the caller for the
/// system default of several seconds. A plain struct around a CF reference: cheap to copy, hashable (two
/// wrappers of the same on-screen object are equal), safe to keep. An element stays usable after the window
/// moves to another Space, but every call fails with `.invalidUIElement` once the window or app is gone.
public struct AXElement: Hashable, @unchecked Sendable {
    /// Messaging timeout in seconds applied to new wrappers unless another value is given.
    public static let defaultMessagingTimeout: Float = 1.0

    public static let fullScreenAttribute = "AXFullScreen"
    public static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

    public let raw: AXUIElement

    /// Wraps `raw`. `timeout` (seconds) is applied with `AXUIElementSetMessagingTimeout`; pass nil to leave
    /// the element's timeout alone.
    public init(_ raw: AXUIElement, timeout: Float? = AXElement.defaultMessagingTimeout) {
        self.raw = raw
        if let timeout { AXUIElementSetMessagingTimeout(raw, timeout) }
    }

    /// The application element of a process.
    public static func application(pid: pid_t, timeout: Float? = AXElement.defaultMessagingTimeout) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid), timeout: timeout)
    }

    /// The system-wide element. Its timeout is the process-wide default for elements without their own.
    public static var systemWide: AXElement {
        AXElement(AXUIElementCreateSystemWide(), timeout: nil)
    }

    public static func == (lhs: AXElement, rhs: AXElement) -> Bool { CFEqual(lhs.raw, rhs.raw) }
    public func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }

    /// Sets how long calls on this element wait for the app (seconds). 0 restores the system default.
    public func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(raw, seconds)
    }

    // MARK: Identity

    /// Owning process, or nil when the element is no longer valid.
    public var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(raw, &pid) == .success ? pid : nil
    }

    /// CGWindowID of a window element (private `_AXUIElementGetWindow`), or nil for non-windows and failures.
    public var windowID: CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(raw, &id) == .success, id != 0 else { return nil }
        return id
    }

    // MARK: Reading attributes

    /// Raw attribute value with the AX error. The value is nil unless the error is `.success`.
    public func read(_ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(raw, attribute as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    public func value(_ attribute: String) -> CFTypeRef? { read(attribute).value }

    public func string(_ attribute: String) -> String? {
        value(attribute) as? String
    }

    public func bool(_ attribute: String) -> Bool? {
        guard let value = value(attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    public func int(_ attribute: String) -> Int? {
        guard let value = value(attribute), CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return (value as? NSNumber)?.intValue
    }

    public func pointValue(_ attribute: String) -> CGPoint? {
        value(attribute).flatMap { Self.point(from: $0) }
    }

    public func sizeValue(_ attribute: String) -> CGSize? {
        value(attribute).flatMap { Self.size(from: $0) }
    }

    public func rectValue(_ attribute: String) -> CGRect? {
        value(attribute).flatMap { Self.rect(from: $0) }
    }

    /// A URL attribute such as AXURL; also accepts a string value (AXDocument holds a URL string).
    public func url(_ attribute: String) -> URL? {
        guard let value = value(attribute) else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() { return (value as? URL) }
        if let text = value as? String { return URL(string: text) }
        return nil
    }

    /// An attribute that holds one element, such as AXFocusedWindow or AXMainWindow.
    public func element(_ attribute: String) -> AXElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeDowncast(value, to: AXUIElement.self))
    }

    /// An attribute that holds a list of elements, such as AXWindows or AXChildren. Empty when unreadable.
    public func elements(_ attribute: String) -> [AXElement] {
        guard let value = value(attribute), let list = value as? [AnyObject] else { return [] }
        return list.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID()
                ? AXElement(unsafeDowncast(item, to: AXUIElement.self)) : nil
        }
    }

    /// Names of all attributes this element supports.
    public var attributeNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    // MARK: Writing attributes

    public func isSettable(_ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(raw, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    public func setValue(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(raw, attribute as CFString, value)
    }

    @discardableResult
    public func set(_ attribute: String, _ value: Bool) -> AXError {
        setValue(attribute, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    @discardableResult
    public func set(_ attribute: String, _ value: String) -> AXError {
        setValue(attribute, value as CFString)
    }

    @discardableResult
    public func set(_ attribute: String, _ value: CGPoint) -> AXError {
        guard let boxed = Self.box(value) else { return .illegalArgument }
        return setValue(attribute, boxed)
    }

    @discardableResult
    public func set(_ attribute: String, _ value: CGSize) -> AXError {
        guard let boxed = Self.box(value) else { return .illegalArgument }
        return setValue(attribute, boxed)
    }

    @discardableResult
    public func set(_ attribute: String, _ value: CGRect) -> AXError {
        guard let boxed = Self.box(value) else { return .illegalArgument }
        return setValue(attribute, boxed)
    }

    @discardableResult
    public func set(_ attribute: String, _ value: AXElement) -> AXError {
        setValue(attribute, value.raw)
    }

    // MARK: Actions

    /// Names of the actions this element supports (for example "AXRaise").
    public var actions: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    @discardableResult
    public func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(raw, action as CFString)
    }

    // MARK: Common window attributes

    public var role: String? { string(kAXRoleAttribute) }
    public var subrole: String? { string(kAXSubroleAttribute) }
    public var title: String? { string(kAXTitleAttribute) }

    /// Global top-left coordinates, like CGWindowList.
    public var position: CGPoint? { pointValue(kAXPositionAttribute) }
    public var size: CGSize? { sizeValue(kAXSizeAttribute) }

    /// Position and size together; nil when either cannot be read.
    public var frame: CGRect? {
        guard let origin = position, let size = size else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Nil when the attribute cannot be read (element gone, or the app does not support it).
    public var isMinimized: Bool? { bool(kAXMinimizedAttribute) }
    public var isFullScreen: Bool? { bool(Self.fullScreenAttribute) }

    // MARK: AXValue helpers

    private static func unbox(_ value: CFTypeRef, _ type: AXValueType) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let boxed = unsafeDowncast(value, to: AXValue.self)
        return AXValueGetType(boxed) == type ? boxed : nil
    }

    private static func point(from value: CFTypeRef) -> CGPoint? {
        guard let boxed = unbox(value, .cgPoint) else { return nil }
        var out = CGPoint.zero
        return AXValueGetValue(boxed, .cgPoint, &out) ? out : nil
    }

    private static func size(from value: CFTypeRef) -> CGSize? {
        guard let boxed = unbox(value, .cgSize) else { return nil }
        var out = CGSize.zero
        return AXValueGetValue(boxed, .cgSize, &out) ? out : nil
    }

    private static func rect(from value: CFTypeRef) -> CGRect? {
        guard let boxed = unbox(value, .cgRect) else { return nil }
        var out = CGRect.zero
        return AXValueGetValue(boxed, .cgRect, &out) ? out : nil
    }

    private static func box(_ point: CGPoint) -> AXValue? {
        var copy = point
        return AXValueCreate(.cgPoint, &copy)
    }

    private static func box(_ size: CGSize) -> AXValue? {
        var copy = size
        return AXValueCreate(.cgSize, &copy)
    }

    private static func box(_ rect: CGRect) -> AXValue? {
        var copy = rect
        return AXValueCreate(.cgRect, &copy)
    }
}
