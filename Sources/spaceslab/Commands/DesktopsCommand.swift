import Foundation
import WMCore

enum DesktopsCommand {
    static let name = "desktops"
    static let help = "List, add and remove Desktops (list, add, remove, dump-tree)"

    static let usage = """
        Usage: spaceslab desktops <command> [options]

          list                                   Desktops and full-screen Spaces per display, with window counts.
                                                 Read-only; never opens Mission Control.
          add [--display n]                      Add a Desktop to display n (default 1).
          remove <desktop number> [--display n] [--force]
                                                 Remove "Desktop <number>" of display n (default 1).
                                                 Refused: Desktop 1, the current Space, full-screen Spaces, and
                                                 Desktops that still have windows (--force overrides only that).
          dump-tree [--max-depth n] [--json]     Open Mission Control, print the Dock's Accessibility tree,
                                                 close it. For debugging when a macOS update changes the tree.

        add, remove and dump-tree open Mission Control for about a second and need Accessibility permission.
        add and remove save a "desktops-add" / "desktops-remove" lab result in ./lab-results.
        Display numbers are the "Display N" numbers of `spaceslab spaces`.

        """

    static func run(_ args: [String]) -> Int32 {
        guard let sub = args.first else {
            fputs(usage, stderr)
            return 2
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list": return list(rest)
        case "add": return add(rest)
        case "remove": return remove(rest)
        case "dump-tree": return dumpTree(rest)
        case "-h", "--help", "help":
            print(usage, terminator: "")
            return 0
        default:
            fputs("desktops: unknown command \(sub)\n\n" + usage, stderr)
            return 2
        }
    }

    // MARK: Option parsing

    struct Options {
        var display = 1
        var force = false
        var json = false
        var maxDepth = 8
        var positional: [String] = []
        var help = false
    }

    /// Parses `--display n`, `--display=n`, `--force`, `--json`, `--max-depth n`, `-h` and positional words.
    /// Only the options in `allowed` are accepted. Returns an error text on bad input.
    static func parse(_ args: [String], allowed: Set<String>) -> (Options, String?) {
        var options = Options()
        var index = 0
        func wholeNumber(_ text: String?) -> Int? {
            guard let text, let number = Int(text), number >= 1 else { return nil }
            return number
        }
        while index < args.count {
            var arg = args[index]
            var inline: String?
            if arg.hasPrefix("--"), let equals = arg.firstIndex(of: "=") {
                inline = String(arg[arg.index(after: equals)...])
                arg = String(arg[..<equals])
            }
            index += 1
            if arg == "-h" || arg == "--help" {
                options.help = true
                continue
            }
            if arg.hasPrefix("-") && !allowed.contains(arg) { return (options, "unknown option \(arg)") }
            switch arg {
            case "--display", "--max-depth":
                let text = inline ?? (index < args.count ? args[index] : nil)
                if inline == nil { index += 1 }
                guard let number = wholeNumber(text) else { return (options, "\(arg) needs a whole number of 1 or more") }
                if arg == "--display" { options.display = number } else { options.maxDepth = number }
            case "--force": options.force = true
            case "--json": options.json = true
            default: options.positional.append(arg)
            }
        }
        return (options, nil)
    }

    // MARK: Labels

    private static func apps(of space: SpaceInfo) -> String {
        space.ownerAppNames.isEmpty ? "unknown app" : space.ownerAppNames.joined(separator: " + ")
    }

    private static func label(_ space: SpaceInfo, in display: DisplaySpaces) -> String {
        switch space.kind {
        case .desktop: return "Desktop \(display.desktopNumber(of: space) ?? 0)"
        case .fullscreen: return "\(space.isSplitView ? "Split View" : "Full screen"): \(apps(of: space))"
        case .other(let raw): return "Other Space (type \(raw))"
        }
    }

    /// "D1[1]* | D2[67] | FS:Safari[12]": compact order line for lab observations. `*` marks the current Space.
    private static func order(of display: DisplaySpaces) -> String {
        display.spaces.map { space -> String in
            let base: String
            switch space.kind {
            case .desktop: base = "D\(display.desktopNumber(of: space) ?? 0)"
            case .fullscreen: base = "\(space.isSplitView ? "SV" : "FS"):\(apps(of: space))"
            case .other(let raw): base = "?\(raw)"
            }
            return "\(base)[\(space.id)]" + (space.isCurrent ? "*" : "")
        }.joined(separator: " | ")
    }

    private static func title(of display: DisplaySpaces, number: Int) -> String {
        if let name = display.displayName { return "Display \(number): \(name) (\(display.displayIdentifier))" }
        return "Display \(number): \(display.displayIdentifier)"
    }

    private static func desktopCount(_ display: DisplaySpaces) -> Int {
        display.spaces.filter { $0.kind == .desktop }.count
    }

    private static func seconds(_ value: TimeInterval) -> String { String(format: "%.3f", value) }

    private static func windowsText(_ count: Int) -> String { "\(count) window\(count == 1 ? "" : "s")" }

    // MARK: list

    static func list(_ args: [String]) -> Int32 {
        let (options, problem) = parse(args, allowed: [])
        if options.help {
            print(usage, terminator: "")
            return 0
        }
        if let problem {
            fputs("desktops list: \(problem)\n", stderr)
            return 2
        }
        if !options.positional.isEmpty {
            fputs("desktops list: unexpected argument \(options.positional[0])\n", stderr)
            return 2
        }

        do {
            let displays = try SpaceReader.displays()
            let windows = WindowCatalog.all().filter { $0.looksLikeUserWindow }
            if displays.isEmpty { print("No displays reported by SkyLight.") }
            for (n, display) in displays.enumerated() {
                if n > 0 { print("") }
                print(title(of: display, number: n + 1))
                for space in display.spaces {
                    var line = "  [\(space.index + 1)] \(label(space, in: display))"
                    if space.isCurrent { line += " (current)" }
                    if space.kind == .desktop {
                        // Windows whose only Space is this Desktop; "all Desktops" windows are counted below.
                        let own = windows.filter { $0.spaceIDs == [space.id] }
                        let names = Set(own.map(\.appName))
                            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                        line += own.isEmpty ? "  no windows" : "  \(windowsText(own.count)): \(names.joined(separator: ", "))"
                    }
                    print(line)
                }
                let fullScreen = display.spaces.count - desktopCount(display)
                var summary = "  \(desktopCount(display)) Desktop\(desktopCount(display) == 1 ? "" : "s")"
                if fullScreen > 0 { summary += ", \(fullScreen) full-screen/other Space\(fullScreen == 1 ? "" : "s")" }
                let ids = Set(display.spaces.map(\.id))
                let everywhere = windows.filter { $0.spaceIDs.count > 1 && !ids.isDisjoint(with: $0.spaceIDs) }
                if !everywhere.isEmpty { summary += "; \(windowsText(everywhere.count)) on several Spaces" }
                print(summary)
            }
            return 0
        } catch {
            fputs("desktops list: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    // MARK: add

    static func add(_ args: [String]) -> Int32 {
        let (options, problem) = parse(args, allowed: ["--display"])
        if options.help {
            print(usage, terminator: "")
            return 0
        }
        if let problem {
            fputs("desktops add: \(problem)\n\n" + usage, stderr)
            return 2
        }
        if !options.positional.isEmpty {
            fputs("desktops add: unexpected argument \(options.positional[0])\n", stderr)
            return 2
        }
        guard requireAccessibility("add") else { return 1 }

        var result = LabResult(test: "desktops-add")
        let driver = MissionControlDriver()
        driver.log = { result.step($0) }
        result.observe("display", String(options.display))
        result.step("add a Desktop to display \(options.display)")
        print("Opening Mission Control to add a Desktop to display \(options.display) ...")

        var success = false
        do {
            let change = try driver.addDesktop(displayIndex: options.display - 1)
            success = true
            record(driver, change: change, into: &result)
            result.observe("new-desktop-number", newDesktopNumber(change))
            print("Added a Desktop to display \(options.display): "
                + "\(change.desktopsBefore) -> \(change.desktopsAfter) Desktops (new Space id "
                + "\(change.diff.added.map(String.init).joined(separator: ", "))).")
        } catch {
            record(driver, change: nil, into: &result)
            result.observe("error", error.localizedDescription)
            result.step("failed: \(error.localizedDescription)")
            fputs("desktops add: \(error.localizedDescription)\n", stderr)
        }
        return finish(&result, driver: driver, success: success)
    }

    private static func newDesktopNumber(_ change: DesktopChange) -> String {
        guard let id = change.diff.added.first,
              let space = change.after.spaces.first(where: { $0.id == id }),
              let number = change.after.desktopNumber(of: space) else { return "unknown" }
        return String(number)
    }

    // MARK: remove

    static func remove(_ args: [String]) -> Int32 {
        let (options, problem) = parse(args, allowed: ["--display", "--force"])
        if options.help {
            print(usage, terminator: "")
            return 0
        }
        if let problem {
            fputs("desktops remove: \(problem)\n\n" + usage, stderr)
            return 2
        }
        guard options.positional.count == 1, let number = Int(options.positional[0]), number >= 1 else {
            fputs("desktops remove: give one Desktop number (1 or more), e.g. `desktops remove 3`\n\n" + usage, stderr)
            return 2
        }

        // Read-only checks first, so a refused run never opens Mission Control.
        let displays: [DisplaySpaces]
        do { displays = try SpaceReader.displays() } catch {
            fputs("desktops remove: \(error.localizedDescription)\n", stderr)
            return 1
        }
        guard displays.indices.contains(options.display - 1) else {
            fputs("desktops remove: display \(options.display) does not exist; \(displays.count) display(s) found\n", stderr)
            return 1
        }
        let display = displays[options.display - 1]
        guard let space = display.spaces.first(where: { display.desktopNumber(of: $0) == number }) else {
            fputs("desktops remove: display \(options.display) has \(desktopCount(display)) Desktop(s); "
                + "there is no Desktop \(number)\n", stderr)
            return 1
        }
        let windows = WindowCatalog.all()
        let blocking = DesktopRemovalPolicy.blockingWindows(onSpace: space.id, in: windows)
        if let refusal = DesktopRemovalPolicy.refusal(for: space, in: display, blockingWindowCount: blocking.count,
                                                      force: options.force) {
            fputs("desktops remove: Desktop \(number) of display \(options.display): \(refusal)\n", stderr)
            if refusal.canForce {
                let names = Set(blocking.map(\.appName)).sorted().joined(separator: ", ")
                fputs("  windows: \(names)\n", stderr)
            }
            return 1
        }
        guard requireAccessibility("remove") else { return 1 }

        var result = LabResult(test: "desktops-remove")
        let driver = MissionControlDriver()
        driver.log = { result.step($0) }
        result.observe("display", String(options.display))
        result.observe("desktop-number", String(number))
        result.observe("space-id", String(space.id))
        result.observe("force", String(options.force))
        result.observe("order-before", order(of: display))
        result.step("remove Desktop \(number) (Space \(space.id)) from display \(options.display)")
        print("Opening Mission Control to remove Desktop \(number) from display \(options.display) ...")

        var success = false
        do {
            let change = try driver.removeDesktop(spaceID: space.id, force: options.force, windows: windows)
            success = true
            record(driver, change: change, into: &result)
            print("Removed Desktop \(number) (Space \(space.id)) from display \(options.display): "
                + "\(change.desktopsBefore) -> \(change.desktopsAfter) Desktops.")
            if !blocking.isEmpty { print("Its \(windowsText(blocking.count)) moved to a neighbouring Desktop.") }
        } catch {
            record(driver, change: nil, into: &result)
            result.observe("error", error.localizedDescription)
            result.step("failed: \(error.localizedDescription)")
            fputs("desktops remove: \(error.localizedDescription)\n", stderr)
        }
        return finish(&result, driver: driver, success: success)
    }

    // MARK: dump-tree

    static func dumpTree(_ args: [String]) -> Int32 {
        let (options, problem) = parse(args, allowed: ["--max-depth", "--json"])
        if options.help {
            print(usage, terminator: "")
            return 0
        }
        if let problem {
            fputs("desktops dump-tree: \(problem)\n\n" + usage, stderr)
            return 2
        }
        if !options.positional.isEmpty {
            fputs("desktops dump-tree: unexpected argument \(options.positional[0])\n", stderr)
            return 2
        }
        guard requireAccessibility("dump-tree") else { return 1 }

        let driver = MissionControlDriver()
        do {
            let tree = try driver.withMissionControlOpen { try driver.dumpTree(maxDepth: options.maxDepth) }
            if options.json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(tree), as: UTF8.self))
            } else {
                print("Dock Accessibility tree while Mission Control is open "
                    + "(macOS \(ProcessInfo.processInfo.operatingSystemVersionString), depth \(options.maxDepth)):")
                print(AXTreeNode.render(tree), terminator: "")
            }
            let times = driver.timings.map { "\($0.name) \(seconds($0.seconds)) s" }.joined(separator: ", ")
            fputs("(\(times))\n", stderr)
            return 0
        } catch {
            fputs("desktops dump-tree: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    // MARK: Shared

    private static func requireAccessibility(_ command: String) -> Bool {
        if AXPermission.isTrusted() { return true }
        fputs("desktops \(command): Accessibility permission is missing for this terminal.\n"
            + "Allow it in System Settings > Privacy & Security > Accessibility, then run the command again.\n", stderr)
        return false
    }

    /// Copies the driver's timings and observations (and the Space order before / after) into the result.
    private static func record(_ driver: MissionControlDriver, change: DesktopChange?, into result: inout LabResult) {
        for timing in driver.timings {
            result.observe("time-\(timing.name)", seconds(timing.seconds))
        }
        let total = driver.timings.reduce(0) { $0 + $1.seconds }
        result.observe("time-total", seconds(total))
        for (key, value) in driver.observations { result.observe(key, value) }
        if let change {
            result.observe("order-before", order(of: change.before))
            result.observe("order-after", order(of: change.after))
            result.observe("display-identifier", change.displayIdentifier)
        }
        // Whatever happened, say where Mission Control ended up.
        result.observe("mission-control-closed", String(!driver.isMissionControlOpen))
    }

    private static func finish(_ result: inout LabResult, driver: MissionControlDriver, success: Bool) -> Int32 {
        result.finish(passed: success)
        do {
            let url = try result.save()
            print("Saved \(url.path)")
        } catch {
            fputs("Could not save the lab result: \(error.localizedDescription)\n", stderr)
        }
        if !driver.timings.isEmpty {
            print("Timings (s): " + driver.timings.map { "\($0.name) \(seconds($0.seconds))" }.joined(separator: ", "))
        }
        return success ? 0 : 1
    }
}
