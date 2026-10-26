import AppKit
import ApplicationServices
import Foundation
import WMCore

/// Read-only probe for `AXRemoteWindows`: shows which windows of an app can be reached through the normal AX
/// list and which only through remote tokens. Nothing is moved, raised, hidden, launched or quit.
enum AXRemoteCommand {
    static let name = "ax-remote"
    static let help = "Read-only: AX elements for windows on other Spaces via remote tokens (--app <name>)"

    static let usage = """
        Usage: spaceslab ax-remote --app <name> [--max-id <n>] [--budget <seconds>] [--all]

          --app <name>       App name or bundle id (exact match first, then "contains").
          --max-id <n>       Highest element id to try (default 1000).
          --budget <sec>     Time limit of one brute-force pass (default 0.5).
          --all              Also list helper-like windows (thin bars, tiny or transparent ones).

        For every window of the app that the window server knows (with its Space) it prints whether the element
        came from the cache, the normal AX list or the remote-token lookup, with timings. A second pass shows
        the warm (cached) cost. While the screen is locked macOS gives only placeholders and nothing resolves.

        """

    struct Options {
        var app = ""
        var maxElementID: UInt64 = 1000
        var budget: TimeInterval = 0.5
        var all = false
    }

    static func run(_ args: [String]) -> Int32 {
        var options = Options()
        var index = 0
        func value(for flag: String) -> String? {
            index += 1
            return index < args.count ? args[index] : nil
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--app":
                guard let text = value(for: arg) else { return usageError("--app needs a name") }
                options.app = text
            case "--max-id":
                guard let text = value(for: arg), let number = UInt64(text) else {
                    return usageError("--max-id needs a number")
                }
                options.maxElementID = number
            case "--budget":
                guard let text = value(for: arg), let number = Double(text), number > 0 else {
                    return usageError("--budget needs a positive number of seconds")
                }
                options.budget = number
            case "--all": options.all = true
            case "-h", "--help":
                print(usage, terminator: "")
                return 0
            default:
                return usageError("unknown option \(arg)")
            }
            index += 1
        }
        guard !options.app.isEmpty else { return usageError("--app is required") }
        return probe(options)
    }

    private static func usageError(_ message: String) -> Int32 {
        fputs("ax-remote: \(message)\n\n" + usage, stderr)
        return 2
    }

    // MARK: Probe

    private static func probe(_ options: Options) -> Int32 {
        guard AXPermission.isTrusted() else {
            fputs("ax-remote: Accessibility permission is missing for this process (see `spaceslab doctor`)\n", stderr)
            return 1
        }
        let apps = AXWindows.runningApps(matching: options.app)
        guard !apps.isEmpty else {
            fputs("ax-remote: no running app matches \"\(options.app)\"\n", stderr)
            return 1
        }

        let locked = isScreenLocked()
        print("Remote token API: \(AXRemoteWindows.isAvailable ? "available" : "MISSING")"
              + "   macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
              + "   screen locked: \(locked ? "YES (AX returns placeholders, nothing can resolve)" : "no")")

        let displays = (try? SpaceReader.displays()) ?? []
        let spaceLabels = labels(for: displays)
        let catalog = WindowCatalog.all()

        for app in apps {
            let pid = app.processIdentifier
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
            let windows = catalog.filter { $0.pid == pid && (options.all || $0.looksLikeUserWindow) }
                .sorted { $0.windowID < $1.windowID }
            print("\n\(name) (pid \(pid)): \(windows.count) window\(windows.count == 1 ? "" : "s") on a Space"
                  + (options.all ? "" : " (use --all for helper-like ones too)"))

            guard !windows.isEmpty else { continue }
            let wanted = Set(windows.map { $0.windowID })

            // Cold: forget the cache so the numbers show real work.
            AXRemoteWindows.invalidate(pid: pid)
            let coldStart = ProcessInfo.processInfo.systemUptime
            let cold = AXRemoteWindows.resolve(pid: pid, wanted: wanted, maxElementID: options.maxElementID,
                                               timeBudget: options.budget)
            let coldTotal = ProcessInfo.processInfo.systemUptime - coldStart

            // Warm: same call again, served from the cache where possible.
            let warmStart = ProcessInfo.processInfo.systemUptime
            let warm = AXRemoteWindows.resolve(pid: pid, wanted: wanted, maxElementID: options.maxElementID,
                                               timeBudget: options.budget)
            let warmTotal = ProcessInfo.processInfo.systemUptime - warmStart

            // Remote-only pass over everything, to compare with the normal list.
            let full = AXRemoteWindows.bruteForce(pid: pid, wanted: nil, maxElementID: options.maxElementID,
                                                  timeBudget: options.budget)

            print("  " + pad("window", 7) + pad("title", 34) + pad("size", 14) + pad("Space (* = visible)", 42) + "resolved by")
            for window in windows {
                let how = describe(window.windowID, in: cold)
                let element = cold.elements[window.windowID]
                var axFrame = ""
                if let element, let frame = element.frame {
                    axFrame = "  AX frame \(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY))"
                        + (frame.size == window.bounds.size ? "" : " (differs from window server)")
                }
                let title = (window.title ?? element?.title ?? "-").prefix(32)
                let size = "\(Int(window.bounds.width))x\(Int(window.bounds.height))"
                let space = window.spaceIDs.compactMap { spaceLabels[$0] }.joined(separator: ", ")
                print("  " + pad(String(window.windowID), 7) + pad(String(title), 34) + pad(size, 14)
                      + pad(space.isEmpty ? "(no Space)" : space, 42) + how + axFrame)
            }

            let missing = wanted.subtracting(cold.elements.keys)
            let bySource = Dictionary(grouping: wanted.compactMap { cold.sources[$0] }, by: { $0 })
                .mapValues { $0.count }
            print("  resolved \(wanted.count - missing.count) of \(wanted.count): "
                  + "cache \(bySource[.cache] ?? 0), normal list \(bySource[.normalList] ?? 0), "
                  + "remote token \(bySource[.remoteToken] ?? 0), not found \(missing.count)")
            print("  normal AX list: \(cold.normalWindowCount) real window(s), \(cold.placeholderCount) placeholder(s), "
                  + ms(cold.normalSeconds))
            print("  remote scan inside the lookup: ids 0...\(options.maxElementID), \(cold.probedElementIDs) tried, "
                  + "\(cold.existingElementIDs) are real elements, stop: \(cold.scanStop.rawValue), \(ms(cold.remoteSeconds))")
            print("  cold lookup total \(ms(coldTotal)); warm (cached) lookup \(ms(warmTotal)), "
                  + "\(warm.sources.values.filter { $0 == .cache }.count) from cache")

            // Cross-check of the byte layout: every window the normal list shows must also come out of the
            // remote scan with the same window id.
            let normal = AXWindows.windows(ofPID: pid).compactMap { $0.windowID }
            let remoteIDs = Set(full.elements.keys)
            let confirmed = normal.filter { remoteIDs.contains($0) }
            print("  remote-only scan: \(full.elements.count) window element(s) of \(full.existing) real elements "
                  + "(\(full.probed) ids tried) in \(ms(full.seconds)), stop: \(full.stop.rawValue); "
                  + "normal list has \(normal.count), "
                  + "\(confirmed.count) of them also found by remote scan")
            if !full.elements.isEmpty {
                let ids = full.elementIDs.sorted { $0.key < $1.key }
                    .map { "window \($0.key) = element \($0.value)" }.joined(separator: ", ")
                print("  remote element ids: \(ids)")
            }
            if cold.normalWindowCount == 0 && full.elements.isEmpty && !windows.isEmpty {
                print("  note: no real AX window anywhere"
                      + (locked ? " - the screen is locked, unlock it and run again." : "."))
            }
        }
        return 0
    }

    // MARK: Formatting

    private static func describe(_ windowID: UInt32, in resolution: AXRemoteWindows.Resolution) -> String {
        guard let source = resolution.sources[windowID] else { return "NOT RESOLVED" }
        switch source {
        case .cache: return "cache"
        case .normalList: return "normal AX list"
        case .remoteToken:
            return "remote token (element \(resolution.remoteElementIDs[windowID].map(String.init) ?? "?"))"
        }
    }

    /// Pads with spaces to `width` and never cuts text.
    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }

    /// Space id -> "Display 1 [3] Desktop 2" / "Display 1 [2] Full screen: Claude", with "*" for visible Spaces.
    private static func labels(for displays: [DisplaySpaces]) -> [UInt64: String] {
        var result: [UInt64: String] = [:]
        for (displayIndex, display) in displays.enumerated() {
            for space in display.spaces {
                let kind: String
                switch space.kind {
                case .desktop:
                    kind = "Desktop \(display.desktopNumber(of: space) ?? 0)"
                case .fullscreen:
                    let owners = space.ownerAppNames.isEmpty ? "unknown app" : space.ownerAppNames.joined(separator: " + ")
                    kind = (space.isSplitView ? "Split View: " : "Full screen: ") + owners
                case .other(let raw):
                    kind = "Space type \(raw)"
                }
                result[space.id] = "Display \(displayIndex + 1) [\(space.index + 1)] \(kind)" + (space.isCurrent ? " *" : "")
            }
        }
        return result
    }

    /// True while the login window covers the screen (CGSSessionScreenIsLocked in the session dictionary).
    private static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
