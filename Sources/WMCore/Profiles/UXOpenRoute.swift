import Foundation

/// The UX-test route `windowsmanager://open?section=studio&profile=X&mode=edit&sheet=save&inspectorTab=options&appearance=dark&size=900x600`.
/// Pure parsing only. The app honours it only when the environment has `WM_UX_TEST=1` (see `isEnabled`).
public struct UXOpenRoute: Equatable, Sendable {
    public enum Section: String, Sendable, CaseIterable { case studio, settings, onboarding, debug, popover }
    public enum Mode: String, Sendable { case view, edit }
    public enum Sheet: String, Sendable { case save, capture, restore, shortcut }
    public enum InspectorTab: String, Sendable { case inspector, options, launch }
    public enum Appearance: String, Sendable { case light, dark }
    public enum Sidebar: String, Sendable { case collapsed, expanded }

    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case notOpenRoute
        case invalid(key: String, value: String)
        public var description: String {
            switch self {
            case .notOpenRoute: return "Not a windowsmanager://open URL"
            case .invalid(let k, let v): return "Invalid \(k): \(v)"
            }
        }
    }

    public var section: Section
    public var profile: String?
    public var mode: Mode?
    public var sheet: Sheet?
    public var inspectorTab: InspectorTab?
    public var appearance: Appearance?
    public var size: CGSize?
    /// Onboarding only: shows the Accessibility step as granted or not (display only, the real permission is untouched).
    public var permission: Permission?
    /// Zero-based index of the tile to select in Edit mode.
    public var selectTile: Int?
    /// Pre-fills the name in the Save sheet (an existing name shows the conflict case).
    public var saveName: String?
    /// Studio sidebar: collapsed to the icon rail or expanded.
    public var sidebar: Sidebar?

    public enum Permission: String, Sendable { case before, after }

    public init(section: Section, profile: String? = nil, mode: Mode? = nil, sheet: Sheet? = nil,
                inspectorTab: InspectorTab? = nil, appearance: Appearance? = nil, size: CGSize? = nil,
                permission: Permission? = nil, selectTile: Int? = nil, saveName: String? = nil, sidebar: Sidebar? = nil) {
        self.section = section; self.profile = profile; self.mode = mode; self.sheet = sheet
        self.inspectorTab = inspectorTab; self.appearance = appearance; self.size = size
        self.permission = permission; self.selectTile = selectTile; self.saveName = saveName; self.sidebar = sidebar
    }

    /// True only when `WM_UX_TEST=1`.
    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["WM_UX_TEST"] == "1"
    }

    /// True when the URL is `windowsmanager://open...` (so the caller can route it before `ControlCommand`).
    public static func matches(_ url: URL) -> Bool {
        url.scheme?.lowercased() == ControlCommand.scheme && (url.host ?? "").lowercased() == "open"
    }

    /// Parses the route. `section` is required; unknown values throw. `size` is `WxH` with both sides at least 100.
    public static func parse(url: URL) throws -> UXOpenRoute {
        guard matches(url), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ParseError.notOpenRoute
        }
        func raw(_ key: String) -> String? {
            let v = comps.queryItems?.first(where: { $0.name == key })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }
        func pick<T: RawRepresentable>(_ key: String, _ type: T.Type) throws -> T? where T.RawValue == String {
            guard let v = raw(key) else { return nil }
            guard let r = T(rawValue: v.lowercased()) else { throw ParseError.invalid(key: key, value: v) }
            return r
        }
        guard let sectionValue = raw("section") else { throw ParseError.invalid(key: "section", value: "") }
        guard let section = Section(rawValue: sectionValue.lowercased()) else {
            throw ParseError.invalid(key: "section", value: sectionValue)
        }
        var size: CGSize?
        if let s = raw("size") {
            let parts = s.lowercased().split(separator: "x")
            guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w >= 100, h >= 100 else {
                throw ParseError.invalid(key: "size", value: s)
            }
            size = CGSize(width: w, height: h)
        }
        var tile: Int?
        if let t = raw("selectTile") {
            guard let n = Int(t), n >= 0 else { throw ParseError.invalid(key: "selectTile", value: t) }
            tile = n
        }
        return UXOpenRoute(section: section, profile: raw("profile"), mode: try pick("mode", Mode.self),
                           sheet: try pick("sheet", Sheet.self), inspectorTab: try pick("inspectorTab", InspectorTab.self),
                           appearance: try pick("appearance", Appearance.self), size: size,
                           permission: try pick("permission", Permission.self), selectTile: tile, saveName: raw("saveName"),
                           sidebar: try pick("sidebar", Sidebar.self))
    }
}
