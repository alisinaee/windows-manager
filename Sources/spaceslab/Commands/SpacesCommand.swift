import AppKit
import Foundation
import WMCore

enum SpacesCommand {
    static let name = "spaces"
    static let help = "List Desktops and full-screen Spaces per display (--json --windows --watch --save)"

    static let usage = """
        Usage: spaceslab spaces [--json] [--windows] [--watch] [--save]

          (no option)  Per display: the Spaces in Mission Control order, apps under each Desktop.
                       (current) marks the visible Space of a display, (active) the one with keyboard focus.
          --json       Print everything (displays, Spaces, windows) as JSON.
          --windows    Also list every window that belongs to a Space, with its Space.
          --watch      Print a compact one-line order per display whenever it changes. Ctrl+C stops.
          --save       Record the order as a "spaces-snapshot" lab result in ./lab-results.

        """

    struct Options {
        var json = false
        var windows = false
        var watch = false
        var save = false
    }

    /// Everything `--json` prints.
    struct Snapshot: Encodable {
        var generated: Date
        var macOS: String
        var activeSpaceID: UInt64
        var displays: [DisplaySpaces]
        var windows: [CatalogWindow]
    }

    static func run(_ args: [String]) -> Int32 {
        var options = Options()
        for arg in args {
            switch arg {
            case "--json": options.json = true
            case "--windows": options.windows = true
            case "--watch": options.watch = true
            case "--save": options.save = true
            case "-h", "--help":
                print(usage, terminator: "")
                return 0
            default:
                fputs("spaces: unknown option \(arg)\n\n" + usage, stderr)
                return 2
            }
        }
        if options.watch && (options.json || options.windows || options.save) {
            fputs("spaces: --watch cannot be combined with --json, --windows or --save\n", stderr)
            return 2
        }

        do {
            if options.watch { return try watch() }

            let displays = try SpaceReader.displays()
            let active = SpaceReader.activeSpaceID()
            let windows = WindowCatalog.all()

            if options.json {
                try printJSON(displays: displays, active: active, windows: windows)
            } else {
                printText(displays: displays, active: active, windows: windows)
                if options.windows { printWindows(displays: displays, windows: windows) }
            }
            if options.save { return try save(displays: displays, active: active, toStderr: options.json) }
            return 0
        } catch {
            fputs("spaces: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    // MARK: Labels

    private static func apps(of space: SpaceInfo) -> String {
        space.ownerAppNames.isEmpty ? "unknown app" : space.ownerAppNames.joined(separator: " + ")
    }

    /// "Desktop 1", "Full screen: Google Chrome (window 84)", "Split View: Safari + Notes (windows 11, 12)".
    static func label(_ space: SpaceInfo, in display: DisplaySpaces) -> String {
        switch space.kind {
        case .desktop:
            return "Desktop \(display.desktopNumber(of: space) ?? 0)"
        case .fullscreen:
            let ids = space.fullScreenWindowIDs.map(String.init).joined(separator: ", ")
            let windows = space.fullScreenWindowIDs.isEmpty
                ? "" : " (window\(space.fullScreenWindowIDs.count > 1 ? "s" : "") \(ids))"
            let prefix = space.isSplitView ? "Split View" : "Full screen"
            return "\(prefix): \(apps(of: space))\(windows)"
        case .other(let raw):
            return "Other Space (type \(raw))"
        }
    }

    /// "D1[1]*", "FS:Google Chrome[37]": short token for the compact order line. `*` marks the current Space.
    static func token(_ space: SpaceInfo, in display: DisplaySpaces) -> String {
        let base: String
        switch space.kind {
        case .desktop: base = "D\(display.desktopNumber(of: space) ?? 0)"
        case .fullscreen: base = "\(space.isSplitView ? "SV" : "FS"):\(apps(of: space))"
        case .other(let raw): base = "?\(raw)"
        }
        return "\(base)[\(space.id)]" + (space.isCurrent ? "*" : "")
    }

    static func order(of display: DisplaySpaces) -> String {
        display.spaces.map { token($0, in: display) }.joined(separator: " | ")
    }

    private static func title(of display: DisplaySpaces, number: Int) -> String {
        if let name = display.displayName { return "Display \(number): \(name) (\(display.displayIdentifier))" }
        return "Display \(number): \(display.displayIdentifier)"
    }

    // MARK: Plain text

    static func printText(displays: [DisplaySpaces], active: UInt64, windows: [CatalogWindow]) {
        if displays.isEmpty { print("No displays reported by SkyLight.") }
        for (n, display) in displays.enumerated() {
            if n > 0 { print("") }
            print(title(of: display, number: n + 1))
            for space in display.spaces {
                var line = "  [\(space.index + 1)] \(label(space, in: display))"
                if space.isCurrent { line += space.id == active ? " (current, active)" : " (current)" }
                print(line)

                guard space.kind == .desktop else { continue }
                let names = Set(windows.filter { $0.looksLikeUserWindow && $0.spaceIDs.contains(space.id) }
                    .map(\.appName)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                print("        " + (names.isEmpty ? "(no windows)" : names.joined(separator: ", ")))
            }
        }
    }

    static func printWindows(displays: [DisplaySpaces], windows: [CatalogWindow]) {
        // space id -> (display number, label)
        var places: [UInt64: (display: Int, index: Int, text: String)] = [:]
        for (n, display) in displays.enumerated() {
            for space in display.spaces {
                places[space.id] = (n + 1, space.index, "Display \(n + 1) [\(space.index + 1)] \(label(space, in: display))")
            }
        }

        let onSpace = windows.filter { !$0.spaceIDs.isEmpty }
        let sorted = onSpace.sorted { a, b in
            let pa = a.spaceIDs.compactMap { places[$0] }.min { ($0.display, $0.index) < ($1.display, $1.index) }
            let pb = b.spaceIDs.compactMap { places[$0] }.min { ($0.display, $0.index) < ($1.display, $1.index) }
            let ka = (pa?.display ?? Int.max, pa?.index ?? Int.max, a.appName.lowercased(), a.windowID)
            let kb = (pb?.display ?? Int.max, pb?.index ?? Int.max, b.appName.lowercased(), b.windowID)
            return ka < kb
        }

        print("")
        print("Windows on a Space (\(onSpace.count) of \(windows.count); the rest belong to no Space):")
        var anyHelper = false
        for window in sorted {
            let helper = !window.looksLikeUserWindow
            anyHelper = anyHelper || helper
            let frame = window.bounds
            let size = "\(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.origin.x)),\(Int(frame.origin.y))"
            let where_: String
            if window.spaceIDs.count > 3 {
                where_ = "all Desktops (\(window.spaceIDs.count) Spaces)"
            } else {
                where_ = window.spaceIDs.map { places[$0]?.text ?? "Space \($0)" }.joined(separator: "; ")
            }
            let titleText = window.title.map { "\"\(shorten($0, 40))\"" } ?? "-"
            print("  \(pad(String(window.windowID), 5, right: true))\(helper ? "*" : " ") "
                + "\(pad(window.appName, 22))  \(pad(titleText, 44))  \(pad(size, 22))  \(where_)")
        }
        if anyHelper { print("  * helper-like window: thin, transparent, tiny or a Stage Manager overlay") }
    }

    private static func shorten(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    private static func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        guard text.count < width else { return text }
        let fill = String(repeating: " ", count: width - text.count)
        return right ? fill + text : text + fill
    }

    // MARK: JSON

    static func printJSON(displays: [DisplaySpaces], active: UInt64, windows: [CatalogWindow]) throws {
        let snapshot = Snapshot(generated: Date(), macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                                activeSpaceID: active, displays: displays, windows: windows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
    }

    // MARK: --save

    static func save(displays: [DisplaySpaces], active: UInt64, toStderr: Bool) throws -> Int32 {
        var result = LabResult(test: "spaces-snapshot")
        let spaceCount = displays.reduce(0) { $0 + $1.spaces.count }
        result.step("read \(displays.count) display(s) with \(spaceCount) Space(s)")
        result.observe("displays", String(displays.count))
        result.observe("active-space", String(active))
        for (n, display) in displays.enumerated() {
            let key = "display-\(n + 1)"
            result.observe("\(key)-identifier", display.displayIdentifier)
            if let name = display.displayName { result.observe("\(key)-name", name) }
            result.observe("\(key)-current", String(display.currentSpaceID))
            result.observe("\(key)-space-ids", display.spaces.map { String($0.id) }.joined(separator: ","))
            result.observe("\(key)-order", order(of: display))
        }
        result.finish()
        let url = try result.save()
        let message = "Saved \(url.path)\n"
        if toStderr { fputs(message, stderr) } else { print(message, terminator: "") }
        return 0
    }

    // MARK: --watch

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Prints one line per display now and again whenever that display's order or current Space changes.
    /// Polls every 0.5 s and also reacts at once to NSWorkspace.activeSpaceDidChangeNotification.
    static func watch() throws -> Int32 {
        var notified = true
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in notified = true }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }

        fputs("Watching Spaces; Ctrl+C to stop. [id] is the Space id, * marks the current Space.\n", stderr)
        var lastLine: [String: String] = [:]
        while true {
            notified = false
            let displays = try SpaceReader.displays()
            for (n, display) in displays.enumerated() {
                let line = "Display \(n + 1) \(display.displayName ?? display.displayIdentifier): \(order(of: display))"
                if lastLine[display.displayIdentifier] != line {
                    lastLine[display.displayIdentifier] = line
                    print("\(timeFormat.string(from: Date()))  \(line)")
                    fflush(stdout)
                }
            }
            _ = waitUntil(timeout: 0.5, interval: 0.02) { notified }
        }
    }
}
