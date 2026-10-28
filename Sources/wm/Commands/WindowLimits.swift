import Foundation
import WMCore

/// `wm windows limits <app> [--probe --yes]`: what the app's windows refuse when resized.
func registerWindowLimitsCommands(_ r: Registry) {
    r.register(Command(["windows", "limits"],
                       summary: "Show which windows of an app cannot be resized (read-only; --probe --yes nudges real windows by 8 pt)",
                       args: [CLIArg("app", "App name or bundle id")],
                       options: [CLIOption("probe", "Actively resize each window by 8 pt and restore it (needs --yes)"),
                                 CLIOption("yes", "Confirm the probe moves real windows")],
                       mutates: false) { a, _ in
        let probe = a.flag("probe")
        if probe && !a.flag("yes") {
            throw CLIFailure.usage("--probe resizes real windows by a few points and restores them; it needs --yes.",
                                   hint: "Run: wm windows limits \(a.positionals[0]) --probe --yes")
        }
        guard AXPermission.isTrusted() else {
            throw CLIFailure(.permission, code: "accessibility_denied", message: "Accessibility access is needed to read windows")
        }
        let apps = AXWindows.runningApps(matching: a.positionals[0])
        guard !apps.isEmpty else {
            throw CLIFailure(.notFound, code: "app_not_found", message: "No running app matches \(a.positionals[0])")
        }
        var rows: [JSONValue] = []
        var lines: [String] = []
        for app in apps {
            for (i, raw) in AXWindows.windows(of: app).enumerated() {
                let el = AXElement(raw)
                let limits = probe ? WindowResizeDetector.probe(el) : WindowResizeDetector.read(el)
                let hints = WindowResizeDetector.hints(el)
                let title = AXWindows.title(of: raw)
                var o: [String: JSONValue] = [
                    "app": .string(app.localizedName ?? ""), "index": .int(i), "title": .string(title),
                    "fixedWidth": .bool(limits.fixedWidth), "fixedHeight": .bool(limits.fixedHeight),
                    "canMove": .bool(limits.canMove), "probed": .bool(probe),
                    "hints": .array(hints.map { .string($0) }),
                ]
                if let m = limits.minSize { o["minSize"] = .object(["width": .double(Double(m.width)), "height": .double(Double(m.height))]) }
                if let m = limits.maxSize { o["maxSize"] = .object(["width": .double(Double(m.width)), "height": .double(Double(m.height))]) }
                rows.append(.object(o))
                lines.append("\(app.localizedName ?? "?") #\(i) \"\(title)\": width \(limits.fixedWidth ? "FIXED" : "resizable"), "
                    + "height \(limits.fixedHeight ? "FIXED" : "resizable"), \(limits.canMove ? "movable" : "not movable")"
                    + (hints.isEmpty ? "" : " [\(hints.joined(separator: ", "))]"))
            }
        }
        return CLIResult(data: .object(["windows": .array(rows)]),
                         text: lines.isEmpty ? "No windows found." : lines.joined(separator: "\n"))
    })
}
