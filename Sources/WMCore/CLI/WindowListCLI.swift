import Foundation
import CoreGraphics

// `wm windows list`: read-only list of the live windows (id, app, Space, frame). Never moves anything.

public struct WindowListSpace: Codable, Equatable {
    public var id: UInt64
    public var display: String
    /// "desktop", "fullscreen" or "other".
    public var kind: String
    /// Desktop number as Mission Control shows it; nil for full-screen and other Spaces.
    public var desktop: Int?
}

public struct WindowListFrame: Codable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
}

public struct WindowListRow: Codable, Equatable {
    public var id: UInt32
    public var app: String
    public var pid: Int32
    public var title: String?
    public var frame: WindowListFrame
    public var onScreen: Bool
    public var spaces: [WindowListSpace]
}

public enum WindowListing {
    public static func rows(windows: [CatalogWindow], displays: [DisplaySpaces], app: String? = nil,
                            spaceID: UInt64? = nil, onScreenOnly: Bool = false, includeSpaceless: Bool = false) -> [WindowListRow] {
        var byID: [UInt64: WindowListSpace] = [:]
        for d in displays {
            for s in d.spaces {
                let kind: String
                switch s.kind { case .desktop: kind = "desktop"; case .fullscreen: kind = "fullscreen"; case .other: kind = "other" }
                byID[s.id] = WindowListSpace(id: s.id, display: d.displayName ?? d.displayIdentifier, kind: kind, desktop: d.desktopNumber(of: s))
            }
        }
        let needle = app?.lowercased()
        return windows.compactMap { w in
            if let needle, !w.appName.lowercased().contains(needle) { return nil }
            if let spaceID, !w.spaceIDs.contains(spaceID) { return nil }
            if onScreenOnly, !w.isOnScreen { return nil }
            if w.spaceIDs.isEmpty, !includeSpaceless { return nil }
            let spaces = w.spaceIDs.map { byID[$0] ?? WindowListSpace(id: $0, display: "unknown", kind: "other", desktop: nil) }
            return WindowListRow(id: w.windowID, app: w.appName, pid: w.pid, title: w.title,
                                 frame: WindowListFrame(x: Double(w.bounds.minX), y: Double(w.bounds.minY),
                                                        width: Double(w.bounds.width), height: Double(w.bounds.height)),
                                 onScreen: w.isOnScreen, spaces: spaces)
        }
    }

    public static func line(_ r: WindowListRow) -> String {
        let space = r.spaces.map { s in s.desktop.map { "Desktop \($0)" } ?? "\(s.kind) \(s.id)" }.joined(separator: ",")
        let f = r.frame
        return "\(r.id)\t\(r.app)\t\(space.isEmpty ? "-" : space)\t\(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height))\t\(r.title ?? "")"
    }
}

public enum WindowListCommands {
    public static func register(_ r: Registry, windows: @escaping () -> [CatalogWindow], displays: @escaping () throws -> [DisplaySpaces]) {
        r.register(Command(["windows", "list"], summary: "List live windows with id, app, Space and frame (read-only)",
                           options: [CLIOption("app", "Only apps whose name contains this", takesValue: true, valueName: "name"),
                                     CLIOption("space", "Only windows on this Space id", takesValue: true, valueName: "id"),
                                     CLIOption("on-screen", "Only windows visible now"),
                                     CLIOption("all", "Include windows that belong to no Space")]) { a, _ in
            var space: UInt64?
            if let s = a.value("space") {
                guard let v = UInt64(s) else { throw CLIFailure.usage("--space needs a Space id (see wm spaces)") }
                space = v
            }
            let rows = WindowListing.rows(windows: windows(), displays: try cliService { try displays() }, app: a.value("app"),
                                          spaceID: space, onScreenOnly: a.flag("on-screen"), includeSpaceless: a.flag("all"))
            return CLIResult(data: .object(["windows": try JSONValue.from(rows)]),
                             text: rows.isEmpty ? "No windows." : rows.map(WindowListing.line).joined(separator: "\n"))
        })
    }
}
