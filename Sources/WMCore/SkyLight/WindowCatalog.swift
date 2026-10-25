import AppKit
import ApplicationServices
import Foundation

/// One normal window (layer 0) from the window server, joined with the Spaces it lives on.
public struct CatalogWindow: Codable, Equatable {
    public var windowID: UInt32
    public var pid: Int32
    public var appName: String
    /// Window title. CoreGraphics only gives titles with Screen Recording permission; for windows on a
    /// current Space we fall back to the Accessibility title. Nil when neither is available.
    public var title: String?
    /// Frame in global screen coordinates (origin top-left of the main display).
    public var bounds: CGRect
    public var alpha: Double
    /// True when the window is on a visible Space and not hidden.
    public var isOnScreen: Bool
    /// Ids of the Spaces the window is on; empty for windows that belong to no Space (menu bar overlays,
    /// hidden helper windows, windows parked by Stage Manager).
    public var spaceIDs: [UInt64]

    public init(windowID: UInt32, pid: Int32, appName: String, title: String?, bounds: CGRect,
                alpha: Double = 1, isOnScreen: Bool = false, spaceIDs: [UInt64] = []) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        self.title = title
        self.bounds = bounds
        self.alpha = alpha
        self.isOnScreen = isOnScreen
        self.spaceIDs = spaceIDs
    }

    /// Heuristic for "a window a person would call a window": it is on a Space, visible, not a thin
    /// toolbar or tiny helper, and not a Stage Manager overlay. Everything else stays in `all()`.
    public var looksLikeUserWindow: Bool {
        !spaceIDs.isEmpty
            && alpha > 0.01
            && min(bounds.width, bounds.height) >= 100
            && appName != "WindowManager"
    }
}

public enum WindowCatalog {
    /// Every normal window (CGWindowList `.optionAll`, layer 0, with an owner), with its Space ids.
    /// `.optionAll` includes windows on Spaces that are not visible, e.g. full-screen windows.
    public static func all() -> [CatalogWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var windows: [CatalogWindow] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            let owner = (info[kCGWindowOwnerName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let appName = owner ?? NSRunningApplication(processIdentifier: pid)?.localizedName
            guard let appName else { continue }

            var bounds = CGRect.zero
            if let dict = info[kCGWindowBounds as String] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) ?? .zero
            }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            windows.append(CatalogWindow(
                windowID: wid, pid: pid, appName: appName, title: title, bounds: bounds,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            ))
        }

        let spaces = SpaceReader.spaces(forWindows: windows.map { $0.windowID })
        for i in windows.indices { windows[i].spaceIDs = spaces[windows[i].windowID] ?? [] }

        fillMissingTitlesFromAccessibility(&windows)
        return windows
    }

    /// AX only sees windows on the Spaces that are visible right now, so only those windows are asked.
    private static func fillMissingTitlesFromAccessibility(_ windows: inout [CatalogWindow]) {
        guard AXPermission.isTrusted() else { return }
        let visibleSpaces: Set<UInt64> = Set(((try? SpaceReader.displays()) ?? []).map { $0.currentSpaceID })
        guard !visibleSpaces.isEmpty else { return }

        // Only windows a person would see; this avoids asking AX about dozens of helper windows.
        let wanted = windows.indices.filter { i in
            let w = windows[i]
            return w.title == nil && w.looksLikeUserWindow && !visibleSpaces.isDisjoint(with: w.spaceIDs)
        }
        let pids = Set(wanted.map { windows[$0].pid })

        var titles: [UInt32: String] = [:]
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            for element in AXWindows.windows(of: app) {
                guard let wid = AXWindows.windowID(of: element) else { continue }
                let title = AXWindows.title(of: element)
                if !title.isEmpty { titles[wid] = title }
            }
        }
        for i in wanted { windows[i].title = titles[windows[i].windowID] }
    }
}
