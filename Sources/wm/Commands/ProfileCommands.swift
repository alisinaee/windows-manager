import CoreGraphics
import Foundation
import WMCore

/// `wm profile ...` (P6.90). Reads and writes profile files through the WMCore services, so the Studio and the
/// CLI make the same edits. `--json` comes from the core envelope; ServiceError maps to exit codes
/// (notFound 3, invalid 2, conflict and failed 1). `WM_PROFILES_DIR` overrides the profiles folder.

/// The profiles folder: `WM_PROFILES_DIR` when set (smoke tests use a temporary folder), else the app's folder.
func profileStoreFromEnvironment() -> ProfileStore {
    if let dir = ProcessInfo.processInfo.environment["WM_PROFILES_DIR"], !dir.isEmpty {
        return ProfileStore(folder: URL(fileURLWithPath: dir, isDirectory: true))
    }
    return ProfileStore()
}

private func profiles() -> ProfileService { ProfileService(store: profileStoreFromEnvironment()) }

/// Runs a service call; every error leaves as a `CLIFailure` with the matching exit code and machine code.
private func service<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let failure as CLIFailure {
        throw failure
    } catch {
        let e = ServiceError.wrap(error)
        let exit: CLIExitCode
        switch e {
        case .notFound: exit = .notFound
        case .invalid: exit = .usage
        case .conflict, .failed: exit = .runtime
        }
        throw CLIFailure(exit, code: e.code, message: e.message)
    }
}

/// The display to act on: `--display` when given, else the only display of the profile.
private func display(_ explicit: String?, profile ref: String) throws -> String {
    if let explicit { return explicit }
    let p = try profiles().show(ref)
    if p.displays.count == 1 { return p.displays[0].uuid }
    throw CLIFailure.usage("The profile has \(p.displays.count) displays; pass --display <uuid>.",
                           hint: "Run: wm profile show \(ref)")
}

private func profileResult(_ p: Profile, _ text: String) throws -> CLIResult {
    CLIResult(data: try JSONValue.from(p), text: text)
}

private func rectJSON(_ r: CGRect) -> JSONValue {
    .object(["x": .double(Double(r.minX)), "y": .double(Double(r.minY)),
             "width": .double(Double(r.width)), "height": .double(Double(r.height))])
}

private func add(_ r: Registry, _ path: [String], _ summary: String, args: [CLIArg] = [],
                 options: [CLIOption] = [], mutates: Bool = true, _ body: @escaping (ParsedArgs) throws -> CLIResult) {
    r.register(Command(path, summary: summary, args: args, options: options, mutates: mutates) { a, _ in
        try service { try body(a) }
    })
}

func registerProfileCommands(_ r: Registry) {
    let profileArg = CLIArg("profile", "Profile name or id")
    let windowArg = CLIArg("window", "Window id from profile show")
    let displayOpt = CLIOption("display", "Display uuid (default: the only display)", takesValue: true, valueName: "uuid")

    // MARK: List, show, create, copy, rename, delete

    add(r, ["profile", "list"], "List profiles", mutates: false) { _ in
        let list = profiles().list()
        let text = list.map { "\($0.name)\t\($0.id.uuidString)\t\($0.windowCount) windows" }.joined(separator: "\n")
        return CLIResult(data: try JSONValue.from(list), text: text.isEmpty ? "No profiles." : text)
    }

    add(r, ["profile", "show"], "Show a profile in full", args: [profileArg], mutates: false) { a in
        CLIResult(data: try JSONValue.from(try profiles().show(a.positionals[0])))
    }

    add(r, ["profile", "create"], "Create an empty profile with one Desktop per display",
        args: [CLIArg("name", "Profile name")],
        options: [CLIOption("icon", "SF Symbol name", takesValue: true, valueName: "symbol")]) { a in
        let icon = a.value("icon")
        let p = try profiles().createBlank(name: a.positionals[0], displays: DisplayMap.current(), icon: icon)
        return try profileResult(p, "Created \"\(p.name)\" (\(p.id.uuidString))")
    }

    add(r, ["profile", "copy"], "Copy a profile (no shortcut on the copy)", args: [profileArg],
        options: [CLIOption("name", "Name of the copy", takesValue: true, valueName: "name")]) { a in
        let p = try profiles().copy(a.positionals[0], name: a.value("name"))
        return try profileResult(p, "Copied to \"\(p.name)\" (\(p.id.uuidString))")
    }

    add(r, ["profile", "rename"], "Rename a profile",
        args: [profileArg, CLIArg("new-name", "The new name")]) { a in
        let p = try profiles().rename(a.positionals[0], to: a.positionals[1])
        return try profileResult(p, "Renamed to \"\(p.name)\"")
    }

    add(r, ["profile", "delete"], "Move a profile to the Trash (needs --yes)", args: [profileArg],
        options: [CLIOption("yes", "Confirm the delete")]) { a in
        guard a.flag("yes") else {
            throw CLIFailure.usage("Deleting \(a.positionals[0]) needs --yes.",
                                   hint: "Run: wm profile delete \(a.positionals[0]) --yes")
        }
        let p = try profiles().delete(a.positionals[0])
        return try profileResult(p, "Moved \"\(p.name)\" to the Trash")
    }

    // MARK: Icon, shortcut, options

    add(r, ["profile", "icon"], "Set the icon (an SF Symbol name; empty restores the default)",
        args: [profileArg, CLIArg("sf-symbol", "SF Symbol name", required: false)]) { a in
        let p = try profiles().setIcon(a.positionals[0], icon: a.positionals.count > 1 ? a.positionals[1] : nil)
        return try profileResult(p, "Icon set to \(p.icon)")
    }

    add(r, ["profile", "shortcut"], "Set or clear the run shortcut, e.g. ctrl+opt+cmd+1",
        args: [profileArg, CLIArg("combo", "Shortcut such as ctrl+opt+cmd+1", required: false)],
        options: [CLIOption("clear", "Remove the shortcut")]) { a in
        let ref = a.positionals[0]
        if a.flag("clear") {
            let p = try profiles().clearShortcut(ref)
            return try profileResult(p, "Shortcut cleared")
        }
        guard a.positionals.count > 1 else {
            throw CLIFailure.usage("Give a shortcut such as ctrl+opt+cmd+1, or --clear.")
        }
        let p = try profiles().setShortcut(ref, shortcut: a.positionals[1])
        return try profileResult(p, "Shortcut set to \(p.options.hotkey ?? "-")")
    }

    add(r, ["profile", "options"], "Show or change profile options (--set key=value, repeatable)",
        args: [profileArg],
        options: [CLIOption("set", "key=value; keys: \(ProfileArgs.optionKeys.joined(separator: ", "))",
                            takesValue: true, valueName: "key=value")]) { a in
        let assignments = a.values("set")
        guard !assignments.isEmpty else {
            return CLIResult(data: try JSONValue.from(try profiles().show(a.positionals[0]).options))
        }
        let change = try ProfileArgs.optionChange(assignments)
        let p = try profiles().setOptions(a.positionals[0], change)
        return try profileResult(p, "Options updated")
    }

    // MARK: Desktops

    add(r, ["profile", "desktop", "add"], "Add a Desktop on a display (optionally at a number)",
        args: [profileArg, CLIArg("number", "Desktop number (1-based)", required: false)],
        options: [displayOpt]) { a in
        let ref = a.positionals[0]
        var at: Int?
        if a.positionals.count > 1 { at = try ProfileArgs.parseInt(a.positionals[1], name: "number") }
        let uuid = try display(a.value("display"), profile: ref)
        let result = try profiles().addDesktop(ref, display: uuid, atNumber: at)
        return try profileResult(result.profile, "Added Desktop \(result.number)")
    }

    add(r, ["profile", "desktop", "remove"], "Remove a Desktop (windows move to --move-to, or stay on another Desktop)",
        args: [profileArg, CLIArg("number", "Desktop number (1-based)")],
        options: [displayOpt, CLIOption("move-to", "Desktop number to move the windows to", takesValue: true, valueName: "n")]) { a in
        let ref = a.positionals[0]
        let number = try ProfileArgs.parseInt(a.positionals[1], name: "number")
        let uuid = try display(a.value("display"), profile: ref)
        let target = try a.value("move-to").map { try ProfileArgs.parseInt($0, name: "--move-to") }
        let p = try profiles().removeDesktop(ref, display: uuid, number: number, moveWindowsTo: target)
        return try profileResult(p, "Removed Desktop \(number)")
    }

    // MARK: Windows

    add(r, ["profile", "window", "add"], "Plan a window for an app on a Desktop; prints the new window id",
        args: [profileArg],
        options: [CLIOption("app", "App name", takesValue: true, valueName: "name"),
                  CLIOption("bundle", "Bundle id", takesValue: true, valueName: "id"),
                  displayOpt,
                  CLIOption("desktop", "Desktop number (default 1)", takesValue: true, valueName: "n"),
                  CLIOption("frame", "x,y,w,h in global points", takesValue: true, valueName: "x,y,w,h"),
                  CLIOption("relative", "x,y,w,h as fractions of the monitor", takesValue: true, valueName: "x,y,w,h")]) { a in
        let ref = a.positionals[0]
        guard let name = a.value("app") else { throw CLIFailure.usage("Give the app with --app <name>.") }
        if a.value("frame") != nil && a.value("relative") != nil {
            throw CLIFailure.usage("Use either --frame or --relative, not both.")
        }
        let frame = try a.value("frame").map { try ProfileArgs.parseRect($0, flag: "--frame") }
        let relative = try a.value("relative").map { try ProfileArgs.parseRect($0, flag: "--relative") }
        let desktop = try ProfileArgs.parseInt(a.value("desktop") ?? "1", name: "--desktop")
        let uuid = try display(a.value("display"), profile: ref)
        let app = AppRef(bundleID: a.value("bundle"), name: name)
        let result = try profiles().addWindow(ref, app: app, display: uuid, desktop: desktop,
                                              frame: frame, relativeFrame: relative)
        let data: JSONValue = .object([
            "profile": try JSONValue.from(result.profile),
            "windowID": .string(result.windowID.uuidString),
        ])
        return CLIResult(data: data, text: "Added window \(result.windowID.uuidString)")
    }

    add(r, ["profile", "window", "remove"], "Remove a planned window",
        args: [profileArg, windowArg]) { a in
        let id = try ProfileArgs.parseUUID(a.positionals[1])
        let p = try profiles().removeWindow(a.positionals[0], window: id)
        return try profileResult(p, "Removed window \(id.uuidString)")
    }

    add(r, ["profile", "window", "move"], "Move a window to another Desktop",
        args: [profileArg, windowArg],
        options: [displayOpt, CLIOption("desktop", "Desktop number (default 1)", takesValue: true, valueName: "n")]) { a in
        let ref = a.positionals[0]
        let id = try ProfileArgs.parseUUID(a.positionals[1])
        let desktop = try ProfileArgs.parseInt(a.value("desktop") ?? "1", name: "--desktop")
        let uuid = try display(a.value("display"), profile: ref)
        let p = try profiles().moveWindow(ref, window: id, display: uuid, desktop: desktop)
        return try profileResult(p, "Moved window to Desktop \(desktop)")
    }

    add(r, ["profile", "window", "frame"], "Set a window frame: x,y,w,h in points (or fractions with --relative)",
        args: [profileArg, windowArg, CLIArg("frame", "x,y,w,h")],
        options: [CLIOption("relative", "Read x,y,w,h as fractions of the monitor")]) { a in
        let ref = a.positionals[0]
        let id = try ProfileArgs.parseUUID(a.positionals[1])
        if a.flag("relative") {
            let rect = try ProfileArgs.parseRect(a.positionals[2], flag: "frame")
            let p = try profiles().setWindowRelativeFrame(ref, window: id, relativeFrame: rect)
            return try profileResult(p, "Window frame set (relative)")
        }
        let rect = try ProfileArgs.parseRect(a.positionals[2], flag: "frame")
        let p = try profiles().setWindowFrame(ref, window: id, frame: rect)
        return try profileResult(p, "Window frame set")
    }

    // MARK: Layout: zones, grid, auto layout

    add(r, ["profile", "zone"], "Put a window into a zone of a saved layout (zone index is 0-based)",
        args: [profileArg, windowArg],
        options: [CLIOption("layout", "Layout name or id", takesValue: true, valueName: "layout"),
                  CLIOption("zone", "Zone index, 0-based", takesValue: true, valueName: "i")]) { a in
        let ref = a.positionals[0]
        let id = try ProfileArgs.parseUUID(a.positionals[1])
        guard let layout = a.value("layout") else { throw CLIFailure.usage("Give the layout with --layout <name>.") }
        guard let zoneText = a.value("zone") else { throw CLIFailure.usage("Give the zone index with --zone <i>.") }
        let index = try ProfileArgs.parseInt(zoneText, name: "--zone", minimum: 0)
        let zones = try LayoutService().zones(of: layout)
        guard zones.indices.contains(index) else {
            throw CLIFailure.usage("Layout \"\(layout)\" has zones 0...\(zones.count - 1); got \(index).")
        }
        let zone = zones[index]
        let p = try profiles().applyZone(ref, window: id, zone: zone.rect, zoneName: zone.name)
        return try profileResult(p, "Window placed in zone \"\(zone.name)\"")
    }

    add(r, ["profile", "grid"], "Snap a window to a grid of --cols by --rows on its monitor",
        args: [profileArg, windowArg],
        options: [CLIOption("cols", "Columns (1-64)", takesValue: true, valueName: "n"),
                  CLIOption("rows", "Rows (1-64)", takesValue: true, valueName: "n")]) { a in
        let ref = a.positionals[0]
        let id = try ProfileArgs.parseUUID(a.positionals[1])
        let grid = try ProfileArgs.parseGrid(columns: a.value("cols"), rows: a.value("rows"))
        let p = try profiles().applyGridSnap(ref, window: id, grid: grid)
        return try profileResult(p, "Snapped to a \(grid.columns)x\(grid.rows) grid")
    }

    add(r, ["profile", "auto-layout"],
        "List auto layout candidates for a Desktop, or apply one with --apply (candidate 0 is the best)",
        args: [profileArg],
        options: [displayOpt,
                  CLIOption("desktop", "Desktop number (default 1)", takesValue: true, valueName: "n"),
                  CLIOption("candidate", "Candidate index, 0-based (default 0)", takesValue: true, valueName: "i"),
                  CLIOption("apply", "Apply the candidate instead of listing")]) { a in
        let ref = a.positionals[0]
        let desktop = try ProfileArgs.parseInt(a.value("desktop") ?? "1", name: "--desktop")
        let uuid = try display(a.value("display"), profile: ref)
        let candidate = try a.value("candidate").map { try ProfileArgs.parseInt($0, name: "--candidate", minimum: 0) }
        if a.flag("apply") {
            let p = try profiles().applyAutoLayout(ref, display: uuid, desktop: desktop, candidate: candidate ?? 0)
            return try profileResult(p, "Applied auto layout candidate \(candidate ?? 0)")
        }
        let list = try profiles().autoLayoutCandidates(ref, display: uuid, desktop: desktop)
        var candidates: [JSONValue] = []
        for (index, c) in list.enumerated() {
            var frames: [String: JSONValue] = [:]
            for (id, rect) in c.frames { frames[id.uuidString] = rectJSON(rect) }
            candidates.append(JSONValue.object([
                "index": JSONValue.int(index),
                "name": JSONValue.string(c.name),
                "frames": JSONValue.object(frames),
            ]))
        }
        let data = JSONValue.array(candidates)
        let text = list.enumerated().map { "\($0.offset)\t\($0.element.name)" }.joined(separator: "\n")
        return CLIResult(data: data, text: text.isEmpty ? "No windows on Desktop \(desktop)." : text)
    }

    // MARK: Launch order

    let itemArg = CLIArg("item", "Item ref: bundle id, app name or 1-based position")

    add(r, ["profile", "launch-order", "get"], "Show the launch order and worst-case time", args: [profileArg], mutates: false) { a in
        let view = try LaunchOrderService(profiles: profiles()).get(a.positionals[0])
        let data: JSONValue = .object([
            "profileID": .string(view.profileID.uuidString),
            "isImplicit": .bool(view.isImplicit),
            "plan": try JSONValue.from(view.plan),
            "worstCaseSeconds": .double(view.worstCaseSeconds),
        ])
        return CLIResult(data: data)
    }

    add(r, ["profile", "launch-order", "set"], "Replace the order with the given items, first to last",
        args: [profileArg, CLIArg("item", "Item refs, first to last", variadic: true)]) { a in
        let p = try LaunchOrderService(profiles: profiles()).setOrder(a.positionals[0], items: Array(a.positionals.dropFirst()))
        return try profileResult(p, "Launch order updated")
    }

    add(r, ["profile", "launch-order", "move"], "Move an item to a 1-based position",
        args: [profileArg, itemArg, CLIArg("position", "1-based position")]) { a in
        let position = try ProfileArgs.parseInt(a.positionals[2], name: "position")
        let p = try LaunchOrderService(profiles: profiles()).move(a.positionals[0], item: a.positionals[1], toPosition: position)
        return try profileResult(p, "Moved \(a.positionals[1]) to position \(position)")
    }

    add(r, ["profile", "launch-order", "delay"], "Seconds to wait after an item (sequential mode)",
        args: [profileArg, itemArg, CLIArg("seconds", "Seconds, 0 or more")]) { a in
        guard let seconds = Double(a.positionals[2]) else {
            throw CLIFailure.usage("seconds must be a number, got \"\(a.positionals[2])\".")
        }
        let p = try LaunchOrderService(profiles: profiles()).setDelay(a.positionals[0], item: a.positionals[1], seconds: seconds)
        return try profileResult(p, "Delay set to \(seconds) s")
    }

    // MARK: Export and import

    add(r, ["profile", "export"], "Export a profile as JSON (to stdout, or --out FILE)", args: [profileArg],
        options: [CLIOption("out", "File to write", takesValue: true, valueName: "file")], mutates: false) { a in
        let ref = a.positionals[0]
        if let out = a.value("out") {
            let url = URL(fileURLWithPath: out)
            try profiles().export(ref, to: url)
            return CLIResult(data: .object(["path": .string(url.path)]), text: "Exported to \(url.path)")
        }
        let bytes = try profiles().exportData(ref)
        let json = try JSONDecoder().decode(JSONValue.self, from: bytes)
        return CLIResult(data: json, text: String(decoding: bytes, as: UTF8.self))
    }

    add(r, ["profile", "import"], "Import a profile file as a new profile (new id, no shortcut)",
        args: [CLIArg("file", "Profile JSON file")]) { a in
        let p = try profiles().importFile(URL(fileURLWithPath: a.positionals[0]))
        return try profileResult(p, "Imported \"\(p.name)\" (\(p.id.uuidString))")
    }
}
