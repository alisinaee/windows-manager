import CoreGraphics
import Foundation

// Plain-text map of a saved profile for the terminal (PM8), printed by `spaceslab profile map <name>`.
// Pure and deterministic: displays in profile order, Spaces in Mission Control order (ProfileSpaceIndex),
// windows back to front and numbered within each Space. No dates, no locale-dependent formatting, ASCII only.
// - Each window line gives its position as percentages of the visible frame (`relativeFrame`).
// - Each Space has a box map: the monitor is drawn as a box of `width` characters and every window as a
//   smaller box, placed by its frame against its display's frame, labelled with its list number.

public enum ProfileMapText {
    /// Default width of a box map, in characters including its border.
    public static let defaultWidth = 60
    /// Narrowest box map; a smaller request is raised to this.
    public static let minimumWidth = 20
    /// Shortest box map, so a small monitor still has room for a window box.
    static let minimumHeight = 5

    /// The profile as plain text, ending with a newline.
    public static func render(profile: Profile, width: Int = defaultWidth) -> String {
        let mapWidth = max(width, minimumWidth)
        let index = ProfileSpaceIndex(profile: profile)
        let windowsByID = Dictionary(profile.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let displaysByUUID = Dictionary(profile.displays.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let displayUUIDs = displayOrder(profile: profile)

        var lines: [String] = []
        lines.append("Profile: \(profile.name)")
        lines.append("Stage Manager: \(stageManagerText(profile.stageManagerOn))")

        if displayUUIDs.isEmpty {
            lines.append("")
            lines.append("No displays and no windows.")
        }
        for uuid in displayUUIDs {
            let display = displaysByUUID[uuid]
            lines.append("")
            lines.append(displayHeader(uuid: uuid, display: display))
            let spaces = index.spaces(onDisplay: uuid)
            if spaces.isEmpty {
                lines.append("  No Spaces.")
            }
            for space in spaces {
                lines += spaceBlock(space, windowsByID: windowsByID, display: display, width: mapWidth)
            }
            lines += trayBlock(index.tray(onDisplay: uuid), windowsByID: windowsByID)
        }

        let minimized = index.tray.filter { $0.reason == .minimized }.count
        lines.append("")
        lines.append("Summary: \(plural(displayUUIDs.count, "display", "displays")) | "
                     + "\(plural(index.spaces.count, "Space", "Spaces")) | "
                     + "\(plural(profile.windows.count, "window", "windows")) | \(minimized) minimized")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Sections

    /// Displays in the order the profile lists them, then any display only a Space or window refers to.
    static func displayOrder(profile: Profile) -> [String] {
        var order: [String] = []
        func note(_ uuid: String) {
            if !order.contains(uuid) { order.append(uuid) }
        }
        profile.displays.forEach { note($0.uuid) }
        profile.spaces.forEach { note($0.displayUUID) }
        profile.windows.forEach { note($0.displayUUID) }
        return order
    }

    static func stageManagerText(_ on: Bool?) -> String {
        if let on { return on ? "on at capture" : "off at capture" }
        return "unknown"
    }

    static func displayHeader(uuid: String, display: DisplayIdentity?) -> String {
        guard let display else { return "Display: \(uuid), size unknown" }
        let size = "\(Int(display.frame.width.rounded()))x\(Int(display.frame.height.rounded())) pt"
        return "Display: \(display.name), \(size)\(display.isMain ? ", main" : "")"
    }

    /// One Space: its heading, its windows as numbered lines, and the box map with a legend.
    static func spaceBlock(_ space: ProfileSpaceIndex.Space, windowsByID: [UUID: WindowSnapshot],
                           display: DisplayIdentity?, width: Int) -> [String] {
        // The index lists windows back to front; the list shows the front window first.
        let windows = Array(space.windowIDs.compactMap { windowsByID[$0] }.reversed())
        var lines = ["  \(spaceTitle(space, windowsByID: windowsByID)) (\(plural(windows.count, "window", "windows")))"]
        if windows.isEmpty {
            lines.append("    (no windows)")
        }
        var boxes: [(label: Character, rect: CGRect)] = []
        for (position, window) in windows.enumerated() {
            let label = listLabel(position)
            lines.append("    [\(label)] \(windowText(window))")
            boxes.append((label: label, rect: placementFraction(window, display: display)))
        }
        // Boxes are drawn back to front, so the front window (listed first) is drawn last.
        lines += boxMap(Array(boxes.reversed()), display: display, width: width).map { "    " + $0 }
        if !windows.isEmpty {
            lines.append("    Legend: digits and letters are the windows listed above; + - | draw each window's box")
        }
        return lines
    }

    static func trayBlock(_ entries: [ProfileSpaceIndex.TrayEntry], windowsByID: [UUID: WindowSnapshot]) -> [String] {
        let sections: [(ProfileSpaceIndex.TrayReason, String)] = [
            (.minimized, "Minimized:"),
            (.onAllDesktops, "On all Desktops:"),
            (.unplaced, "Unplaced:"),
        ]
        var lines: [String] = []
        for (reason, heading) in sections {
            let items = entries.filter { $0.reason == reason }.compactMap { windowsByID[$0.windowID] }
            guard !items.isEmpty else { continue }
            lines.append("  \(heading)")
            lines += items.map { "    \(windowText($0))" }
        }
        return lines
    }

    static func spaceTitle(_ space: ProfileSpaceIndex.Space, windowsByID: [UUID: WindowSnapshot]) -> String {
        switch space.kind {
        case .desktop:
            return "Desktop \(space.desktopNumber ?? space.position + 1)"
        case .fullScreen:
            let names = space.fullScreenWindowIDs.map { windowsByID[$0]?.app.name ?? "unknown app" }
            if names.isEmpty { return "Full screen: (no owner)" }
            return space.isSplitView ? "Split View: \(names.joined(separator: " + "))" : "Full screen: \(names[0])"
        case .other:
            return "Other Space \(space.position + 1)"
        }
    }

    /// `App - "title"  (x%,y% w%xh%)`; the title is left out when there is none.
    static func windowText(_ window: WindowSnapshot) -> String {
        var text = window.app.name
        if let title = window.title, !title.isEmpty {
            text += " - \"\(title)\""
        }
        let r = window.relativeFrame
        return text + "  (\(percent(r.minX))%,\(percent(r.minY))% \(percent(r.width))%x\(percent(r.height))%)"
    }

    // MARK: Box map

    /// Draws the display as a box of `width` characters and each window as a box inside it.
    /// Boxes are drawn in the order given (back to front), so later ones cover earlier ones.
    /// Each row has its trailing spaces removed. The height follows the display's aspect ratio,
    /// with characters taken as twice as tall as they are wide.
    static func boxMap(_ boxes: [(label: Character, rect: CGRect)], display: DisplayIdentity?, width: Int) -> [String] {
        var ratio = 0.5
        if let frame = display?.frame, frame.width > 0, frame.height > 0 {
            ratio = Double(frame.height / frame.width)
        }
        let height = max(minimumHeight, Int((Double(width) * ratio / 2).rounded()))
        let innerWidth = width - 2
        let innerHeight = height - 2

        var grid = Array(repeating: Array(repeating: Character(" "), count: width), count: height)
        for column in 0..<width {
            grid[0][column] = "-"
            grid[height - 1][column] = "-"
        }
        for row in 0..<height {
            grid[row][0] = "|"
            grid[row][width - 1] = "|"
        }
        for (row, column) in [(0, 0), (0, width - 1), (height - 1, 0), (height - 1, width - 1)] {
            grid[row][column] = "+"
        }

        for box in boxes {
            let rect = clampUnit(box.rect)
            var (left, right) = span(from: Double(rect.minX) * Double(innerWidth),
                                     to: Double(rect.maxX) * Double(innerWidth), inner: innerWidth)
            var (top, bottom) = span(from: Double(rect.minY) * Double(innerHeight),
                                     to: Double(rect.maxY) * Double(innerHeight), inner: innerHeight)
            // Offsets are into the inner area; the grid has the display border around it.
            left += 1
            right += 1
            top += 1
            bottom += 1
            // A window box needs a border on each side and a label between them.
            (left, right) = widen(left, right, lowest: 1, highest: width - 2)
            (top, bottom) = widen(top, bottom, lowest: 1, highest: height - 2)

            for row in top...bottom {
                for column in left...right {
                    grid[row][column] = " "
                }
            }
            for column in left...right {
                grid[top][column] = "-"
                grid[bottom][column] = "-"
            }
            for row in top...bottom {
                grid[row][left] = "|"
                grid[row][right] = "|"
            }
            for (row, column) in [(top, left), (top, right), (bottom, left), (bottom, right)] {
                grid[row][column] = "+"
            }
            grid[(top + bottom) / 2][(left + right) / 2] = box.label
        }
        return grid.map { trimTrailing(String($0)) }
    }

    /// Start and end cell offsets (0-based, inclusive) of a span in the inner area.
    static func span(from start: Double, to end: Double, inner: Int) -> (Int, Int) {
        let first = clamp(Int(start.rounded(.down)), 0, inner - 1)
        let last = clamp(Int(end.rounded(.up)) - 1, 0, inner - 1)
        return (first, max(first, last))
    }

    /// Grows a span to at least two cells apart (three cells, with a label between borders), inside `lowest...highest`.
    static func widen(_ start: Int, _ end: Int, lowest: Int, highest: Int) -> (Int, Int) {
        var first = start
        var last = max(end, start)
        if last - first < 2 { last = min(first + 2, highest) }
        if last - first < 2 { first = max(last - 2, lowest) }
        return (first, last)
    }

    // MARK: Helpers

    /// The window's place on its display, as fractions of the display frame. Falls back to `relativeFrame`
    /// when the display or the window has no usable frame.
    static func placementFraction(_ window: WindowSnapshot, display: DisplayIdentity?) -> CGRect {
        guard let frame = display?.frame, frame.width > 0, frame.height > 0,
              window.frame.width > 0, window.frame.height > 0 else {
            return window.relativeFrame
        }
        return CGRect(x: (window.frame.minX - frame.minX) / frame.width,
                      y: (window.frame.minY - frame.minY) / frame.height,
                      width: window.frame.width / frame.width,
                      height: window.frame.height / frame.height)
    }

    /// Clips a rectangle to the unit square. A rectangle with non-finite values becomes empty.
    static func clampUnit(_ rect: CGRect) -> CGRect {
        let values = [rect.minX, rect.minY, rect.maxX, rect.maxY]
        guard values.allSatisfy({ $0.isFinite }) else { return .zero }
        let x0 = min(max(rect.minX, 0), 1), x1 = min(max(rect.maxX, 0), 1)
        let y0 = min(max(rect.minY, 0), 1), y1 = min(max(rect.maxY, 0), 1)
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
    }

    static func percent(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value * 100).rounded())
    }

    /// Label of the window at `position` in its Space's list: 1-9, then a-z, then `*`.
    static func listLabel(_ position: Int) -> Character {
        if position < 9 { return Character(String(position + 1)) }
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let letter = position - 9
        return letter < letters.count ? letters[letter] : "*"
    }

    static func clamp(_ value: Int, _ lowest: Int, _ highest: Int) -> Int {
        min(max(value, lowest), highest)
    }

    static func trimTrailing(_ text: String) -> String {
        var trimmed = Substring(text)
        while trimmed.last == " " {
            trimmed.removeLast()
        }
        return String(trimmed)
    }

    static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }
}
