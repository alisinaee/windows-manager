import Foundation
import WMCore

enum CaptureCommand {
    static let name = "capture"
    static let help = "Capture every display, Space and window into a profile (--name --json --out FILE)"

    static let usage = """
        Usage: spaceslab capture [--name NAME] [--json] [--out FILE]

          (no option)  Per display: the Spaces in Mission Control order with the windows on each
                       (app - title - frame - placement), then the warnings.
          --name NAME  Name of the profile (default "Captured workspace").
          --json       Print the profile as JSON instead of the summary (warnings go to stderr).
          --out FILE   Also write the profile JSON to FILE.

        Read-only: nothing is moved, shown, hidden, launched or quit. Needs Accessibility access for document
        paths and minimized windows, and an unlocked screen.

        """

    static func run(_ args: [String]) -> Int32 {
        var profileName = "Captured workspace"
        var json = false
        var outPath: String?

        var index = 0
        while index < args.count {
            switch args[index] {
            case "--json":
                json = true
                index += 1
            case "--name", "--out":
                guard index + 1 < args.count else {
                    fputs("capture: \(args[index]) needs a value\n\n" + usage, stderr)
                    return 2
                }
                if args[index] == "--name" { profileName = args[index + 1] } else { outPath = args[index + 1] }
                index += 2
            case "-h", "--help":
                print(usage, terminator: "")
                return 0
            default:
                fputs("capture: unknown option \(args[index])\n\n" + usage, stderr)
                return 2
            }
        }

        let scan = WorkspaceScanner.scan()
        let (profile, warnings) = ProfileCapture.makeProfile(name: profileName, from: scan)

        do {
            let data = try ProfileStore.encode(profile)
            if let outPath {
                try data.write(to: URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath), options: .atomic)
            }
            if json {
                print(String(decoding: data, as: UTF8.self))
                for warning in warnings { fputs("warning: \(warning)\n", stderr) }
                if let outPath { fputs("Wrote \(outPath)\n", stderr) }
            } else {
                printSummary(scan: scan, profile: profile, warnings: warnings)
                if let outPath { print("\nWrote \(outPath)") }
            }
            return 0
        } catch {
            fputs("capture: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    // MARK: Summary

    static func printSummary(scan: WorkspaceScan, profile: Profile, warnings: [String]) {
        let spaceCount = profile.spaces.count
        print("Captured \"\(profile.name)\": \(profile.displays.count) display(s), \(spaceCount) Space(s), "
            + "\(profile.windows.count) window(s), \(profile.apps.count) app(s)")
        print("Accessibility: " + (scan.screenIsLocked ? "not read (screen locked)"
            : scan.accessibilityTrusted ? "read" : "not granted"))

        for (n, display) in scan.displays.enumerated() {
            print("")
            print("Display \(n + 1): \(display.name)\(display.isMain ? " (main)" : "")  \(size(display.frame))  \(display.uuid)")
            guard let list = scan.spaces(onDisplay: display.uuid) else {
                print("  (no Spaces known for this display)")
                continue
            }

            let windows = scan.windows.filter { $0.displayUUID?.caseInsensitiveCompare(display.uuid) == .orderedSame }
            var byPlacement: [(window: LiveWindow, placement: SpacePlacement)] = []
            for window in windows { byPlacement.append((window, WorkspaceScanner.placement(for: window, in: scan))) }

            let everywhere = byPlacement.filter { $0.placement == .allDesktops }
            if !everywhere.isEmpty {
                print("  [all Desktops]")
                for entry in everywhere { print("      " + line(entry.window, entry.placement)) }
            }

            for space in list.spaces {
                var header = "  [\(space.index + 1)] " + label(space, in: list)
                if space.id == list.currentSpaceID { header += space.id == scan.activeSpaceID ? " (current, active)" : " (current)" }
                print(header)
                let here = byPlacement.filter { entry in
                    switch entry.placement {
                    case .desktop(let number): return space.kind == .desktop && list.desktopNumber(of: space) == number
                    case .fullScreen(let position): return position == space.index
                    case .allDesktops, .unknown: return false
                    }
                }
                if here.isEmpty { print("      (no windows)") }
                for entry in here { print("      " + line(entry.window, entry.placement)) }
            }

            let nowhere = byPlacement.filter { $0.placement == .unknown }
            if !nowhere.isEmpty {
                print("  [not on a Space]")
                for entry in nowhere { print("      " + line(entry.window, entry.placement)) }
            }
        }

        let unplaced = scan.windows.filter { window in
            window.displayUUID.flatMap { scan.display(withUUID: $0) } == nil
        }
        if !unplaced.isEmpty {
            print("")
            print("Windows on no known display:")
            for window in unplaced { print("      " + line(window, WorkspaceScanner.placement(for: window, in: scan))) }
        }

        print("")
        if warnings.isEmpty {
            print("No warnings.")
        } else {
            print("Warnings (\(warnings.count)):")
            for warning in warnings { print("  - \(warning)") }
        }
    }

    private static func label(_ space: SpaceInfo, in list: ScannedSpaces) -> String {
        switch space.kind {
        case .desktop:
            return "Desktop \(list.desktopNumber(of: space) ?? 0)"
        case .fullscreen:
            let apps = space.ownerAppNames.isEmpty ? "unknown app" : space.ownerAppNames.joined(separator: " + ")
            return "\(space.isSplitView ? "Split View" : "Full screen"): \(apps)"
        case .other(let raw):
            return "Other Space (type \(raw))"
        }
    }

    /// `app - "title" - 1200x800 at 100,200 - Desktop 1`, with flags for full screen, minimized, document.
    private static func line(_ window: LiveWindow, _ placement: SpacePlacement) -> String {
        var parts = [window.app.name]
        parts.append(window.title.map { "\"\(shorten($0, 48))\"" } ?? "(no title)")
        parts.append(size(window.frame))
        parts.append(describe(placement))
        var flags: [String] = []
        if window.isMinimized { flags.append("minimized") }
        if window.app.bundleID == nil { flags.append("no bundle id") }
        if window.indexInApp > 0 { flags.append("#\(window.indexInApp + 1) of app") }
        if let path = window.documentPath { flags.append("document \(path)") }
        return parts.joined(separator: " - ") + (flags.isEmpty ? "" : "  [" + flags.joined(separator: ", ") + "]")
    }

    private static func describe(_ placement: SpacePlacement) -> String {
        switch placement {
        case .desktop(let number): return "Desktop \(number)"
        case .fullScreen(let position): return "full-screen Space \(position + 1)"
        case .allDesktops: return "all Desktops"
        case .unknown: return "unknown"
        }
    }

    private static func size(_ frame: CGRect) -> String {
        "\(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY))"
    }

    private static func shorten(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
