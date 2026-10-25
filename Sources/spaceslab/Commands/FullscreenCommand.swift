import AppKit
import Foundation
import WMCore

enum FullscreenCommand {
    static let name = "fullscreen"
    static let help = "Enter/exit full screen and record where the new Space appears (--probe, enter, exit, test)"

    static let usage = """
        Usage:
          spaceslab fullscreen --probe [--app <name>] [--title <text>]
          spaceslab fullscreen enter --app <name> [--title <text>] [options]
          spaceslab fullscreen exit  --app <name> [--title <text>] [options]
          spaceslab fullscreen test  --app <A> [--app <B> ...] [--keep] [options]

          --probe      Read only. Lists the windows of the given apps (all apps when none is given) that are on the
                       current Space and whether each exposes AXFullScreen and a full-screen menu item.
          enter        Capture one window of the app, wait --delay seconds, trigger full screen, wait up to 6 s until
                       the window owns a full-screen Space, then record where the Space went. Saves "fullscreen-enter".
          exit         Same for leaving full screen; records which Desktop the window returns to. Saves "fullscreen-exit".
                       Accessibility only lists windows of the current Space: stand on the app's full-screen Space first.
          test         Records the Space order, enters each --app in the order given (placement, timings and order after
                       each), then unless --keep exits them in reverse order and records where each window returned.
                       All windows are captured before anything changes. Saves "fullscreen-order".

        Options:
          --app <name>      App name or bundle id (repeat for test). Windows must be on the current Space.
          --title <text>    Only windows whose title contains the text; applies to the --app just before it.
          --method <m>      ax (set AXFullScreen, default), menu (AXPress the app's full-screen menu item) or
                            keys (post Ctrl+Cmd+F to the app's pid).
          --focus           Bring the app and window to the front before triggering (default for menu and keys).
          --no-focus        Never do that, even for menu and keys.
          --delay <sec>     Wait this long after capturing and before the first trigger, so you can switch to another
                            Desktop and test whether a window captured earlier still goes full screen (enter, test).
          --keep            test only: leave the windows in full screen (exit them later with "fullscreen exit").

        Safe way to try it: use simple apps such as TextEdit and Notes, each with one window open on a normal
        Desktop. Calculator is not full-screen capable (--probe shows that). Turn off "Automatically rearrange Spaces
        based on most recent use" first (spaceslab doctor shows it), or the order drifts by itself.
        The commands really enter and leave full screen; do not touch the keyboard or mouse while they run.

        """

    enum Mode { case probe, enter, exit, test }

    struct AppSpec {
        var name: String
        var title: String?
    }

    struct Options {
        var mode: Mode = .probe
        var apps: [AppSpec] = []
        var method: FullScreenMethod = .ax
        var focus: Bool?
        var keep = false
        var delay: TimeInterval = 0
    }

    // MARK: Entry point

    static func run(_ args: [String]) -> Int32 {
        let options: Options
        switch parse(args) {
        case .success(let parsed):
            options = parsed
        case .failure(let message):
            if message.isEmpty {
                print(usage, terminator: "")
                return 0
            }
            fputs("fullscreen: \(message)\n\n" + usage, stderr)
            return 2
        }

        guard AXPermission.isTrusted() else {
            fputs("fullscreen: Accessibility is not trusted for this terminal. Run `spaceslab doctor` for the steps.\n", stderr)
            return 1
        }
        guard (try? SpaceReader.displays()) != nil else {
            fputs("fullscreen: SkyLight could not be read. Run `spaceslab doctor`.\n", stderr)
            return 1
        }

        switch options.mode {
        case .probe: return runProbe(options)
        case .enter: return runSingle(options, entering: true)
        case .exit: return runSingle(options, entering: false)
        case .test: return runTest(options)
        }
    }

    enum ParseResult {
        case success(Options)
        /// Empty message means "show help".
        case failure(String)
    }

    static func parse(_ args: [String]) -> ParseResult {
        var options = Options()
        var rest = args[...]
        guard let first = rest.first else { return .failure("a mode is required (--probe, enter, exit or test)") }
        switch first {
        case "-h", "--help", "help": return .failure("")
        case "--probe": options.mode = .probe
        case "enter": options.mode = .enter
        case "exit": options.mode = .exit
        case "test": options.mode = .test
        default: return .failure("unknown mode \(first)")
        }
        rest = rest.dropFirst()

        func value(for option: String) -> String? {
            rest = rest.dropFirst()
            guard let next = rest.first else { return nil }
            return next
        }

        while let arg = rest.first {
            switch arg {
            case "-h", "--help":
                return .failure("")
            case "--app":
                guard let name = value(for: arg), !name.hasPrefix("--") else { return .failure("--app needs a name") }
                options.apps.append(AppSpec(name: name, title: nil))
            case "--title":
                guard let text = value(for: arg) else { return .failure("--title needs a text") }
                guard !options.apps.isEmpty else { return .failure("--title must come after the --app it belongs to") }
                options.apps[options.apps.count - 1].title = text
            case "--method":
                guard let text = value(for: arg), let method = FullScreenMethod(rawValue: text) else {
                    return .failure("--method must be ax, menu or keys")
                }
                options.method = method
            case "--focus": options.focus = true
            case "--no-focus": options.focus = false
            case "--keep": options.keep = true
            case "--delay":
                guard let text = value(for: arg), let seconds = TimeInterval(text), seconds >= 0, seconds <= 120 else {
                    return .failure("--delay needs a number of seconds between 0 and 120")
                }
                options.delay = seconds
            default:
                return .failure("unknown option \(arg)")
            }
            rest = rest.dropFirst()
        }

        switch options.mode {
        case .probe:
            if options.keep || options.delay > 0 { return .failure("--keep and --delay do not apply to --probe") }
        case .enter, .exit:
            if options.apps.count != 1 { return .failure("\(options.mode == .enter ? "enter" : "exit") needs exactly one --app") }
            if options.keep { return .failure("--keep only applies to test") }
            if options.mode == .exit && options.delay > 0 { return .failure("--delay only applies to enter and test") }
        case .test:
            if options.apps.isEmpty { return .failure("test needs at least one --app (two or more answer the ordering question)") }
        }
        return .success(options)
    }

    // MARK: Shared pieces

    /// Prints each line and records it as a lab step.
    final class Run {
        var result: LabResult

        init(test: String) {
            result = LabResult(test: test)
        }

        func log(_ message: String) {
            print(message)
            fflush(stdout)
            result.step(message)
        }

        func observe(_ key: String, _ value: String) {
            result.observe(key, value)
        }
    }

    /// Integer text for a screen length; safe for NaN or infinity.
    static func whole(_ value: CGFloat) -> String {
        value.isFinite ? String(Int(value.rounded())) : "?"
    }

    static func seconds(_ value: TimeInterval?) -> String {
        value.map { String(format: "%.2f s", $0) } ?? "-"
    }

    static func autoRearrangeIsOn() -> Bool {
        (UserDefaults(suiteName: "com.apple.dock")?.object(forKey: "mru-spaces") as? Bool) ?? true
    }

    /// "Desktop 2 [id 7]", "Full screen: TextEdit (window 12) [id 88]" or "Space 5".
    static func place(_ spaceID: UInt64?, in displays: [DisplaySpaces]) -> String {
        guard let spaceID else { return "unknown" }
        for display in displays {
            if let space = display.spaces.first(where: { $0.id == spaceID }) {
                return "\(SpacesCommand.label(space, in: display)) [id \(spaceID)]"
            }
        }
        return "Space \(spaceID)"
    }

    static func orderLine(_ displays: [DisplaySpaces], identifier: String?) -> String {
        guard let display = displays.first(where: { $0.displayIdentifier == identifier }) ?? displays.first else { return "-" }
        return SpacesCommand.order(of: display)
    }

    /// "FS:TextEdit[88]" tokens of the Spaces left and right of `spaceID`.
    static func neighbours(of spaceID: UInt64, in displays: [DisplaySpaces]) -> String {
        for display in displays {
            guard let index = display.spaces.firstIndex(where: { $0.id == spaceID }) else { continue }
            let left = index > 0 ? SpacesCommand.token(display.spaces[index - 1], in: display) : "(start of list)"
            let right = index + 1 < display.spaces.count ? SpacesCommand.token(display.spaces[index + 1], in: display) : "(end of list)"
            return "left \(left), right \(right), position \(index + 1) of \(display.spaces.count)"
        }
        return "-"
    }

    static func describe(_ diff: OrderDiff, in display: DisplaySpaces?, before: DisplaySpaces?) -> String {
        guard let display else { return "-" }
        var parts: [String] = []
        for space in diff.added { parts.append("added \(SpacesCommand.token(space, in: display)) at position \(space.index + 1)") }
        for space in diff.removed {
            parts.append("removed \(before.map { SpacesCommand.token(space, in: $0) } ?? "Space \(space.id)")")
        }
        if diff.reordered { parts.append("reordered (moved \(diff.movedIDs.map(String.init).joined(separator: ", ")))") }
        if diff.currentChanged { parts.append("current \(diff.currentBefore) -> \(diff.currentAfter)") }
        return parts.isEmpty ? "no change" : parts.joined(separator: "; ")
    }

    static func placementText(_ t: FullScreenTransition) -> String {
        guard let placement = t.placement else { return "unknown" }
        var text = placement.description
        if t.placementMatches.count > 1 {
            text += " (also fits: \(t.placementMatches.dropFirst().map(\.description).joined(separator: ", ")))"
        }
        return text
    }

    enum Resolved {
        case found(FullScreenTarget)
        case failed(String)
    }

    /// Picks the window to act on: usable = not minimized, and full screen (exit) or not (enter).
    static func resolve(_ spec: AppSpec, forExit: Bool) -> Resolved {
        let all = FullScreenProbe.capture(appQuery: spec.name, titleContains: spec.title)
        if all.isEmpty {
            let apps = AXWindows.runningApps(matching: spec.name)
            if apps.isEmpty { return .failed("no running app matches \"\(spec.name)\"") }
            return .failed("no standard window of \(apps.compactMap(\.localizedName).joined(separator: ", ")) is visible to Accessibility"
                + (spec.title.map { " with \"\($0)\" in the title" } ?? "")
                + ". Accessibility only lists windows on the current Space; open a window of the app on this Desktop"
                + (forExit ? " (for exit: stand on the app's full-screen Space)." : "."))
        }
        let usable = all.filter { forExit ? $0.isFullScreen : (!$0.isFullScreen && !$0.isMinimized) }
        guard let chosen = usable.first else {
            return .failed(forExit
                ? "\(all[0].appName) has no full-screen window visible to Accessibility; stand on its full-screen Space and run again"
                : "every matching window of \(all[0].appName) is already full screen or minimized")
        }
        return .found(chosen)
    }

    static func countdown(_ delay: TimeInterval, reason: String) {
        guard delay > 0 else { return }
        print(reason)
        var left = Int(delay.rounded(.up))
        while left > 0 {
            print("  \(left)...")
            fflush(stdout)
            waitUntil(timeout: 1) { false }
            left -= 1
        }
    }

    // MARK: --probe

    static func runProbe(_ options: Options) -> Int32 {
        let displays = (try? SpaceReader.displays()) ?? []
        let active = SpaceReader.activeSpaceID()
        print("Current Space: \(place(active, in: displays))")
        if autoRearrangeIsOn() {
            print("Note: \"Automatically rearrange Spaces based on most recent use\" is ON; turn it off before `fullscreen test`.")
        }
        print("Accessibility only lists windows on the current Space, so only those are probed.\n")

        var apps: [NSRunningApplication] = []
        if options.apps.isEmpty {
            apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        } else {
            for spec in options.apps {
                let found = AXWindows.runningApps(matching: spec.name)
                if found.isEmpty { print("\(spec.name): no running app matches\n") }
                apps.append(contentsOf: found)
            }
        }

        var shown = 0
        var seenPIDs = Set<Int32>()
        for app in apps where seenPIDs.insert(app.processIdentifier).inserted {
            let titleFilter = options.apps.first { spec in
                AXWindows.runningApps(matching: spec.name).contains { $0.processIdentifier == app.processIdentifier }
            }?.title
            let windows = FullScreenProbe.capture(apps: [app], titleContains: titleFilter, standardWindowsOnly: false)
            if windows.isEmpty {
                if !options.apps.isEmpty { print("\(app.localizedName ?? "pid \(app.processIdentifier)"): no windows on the current Space\n") }
                continue
            }
            shown += 1
            let bundle = app.bundleIdentifier.map { ", \($0)" } ?? ""
            print("\(app.localizedName ?? "pid \(app.processIdentifier)") (pid \(app.processIdentifier)\(bundle))")
            let menu = FullScreenProbe.findFullScreenMenuItem(pid: app.processIdentifier, entering: nil)
            if let menu {
                print("  menu: \"\(menu.path)\" (\(menu.enabled ? "enabled" : "disabled"))")
            } else {
                print("  menu: no full-screen item found in the menu bar")
            }
            for window in windows {
                let ax = FullScreenProbe.axFullScreenInfo(of: window)
                let size = window.frame.map { "\(whole($0.width))x\(whole($0.height))" } ?? "?"
                let axText = ax.readable
                    ? "AXFullScreen readable, \(ax.settable ? "settable" : "NOT settable"), value \(ax.value.map { $0 ? "true" : "false" } ?? "?")"
                    : "AXFullScreen not exposed"
                let flags = [window.isMain ? "main" : nil, window.isMinimized ? "minimized" : nil,
                             window.isFullScreen ? "full screen" : nil].compactMap { $0 }
                print("  window \(window.windowID)  \(window.title.isEmpty ? "(no title)" : "\"\(window.title)\"")  \(size)  "
                    + "\(window.subrole.isEmpty ? "no subrole" : window.subrole)\(flags.isEmpty ? "" : "  [" + flags.joined(separator: ", ") + "]")")
                print("    \(axText); on \(window.originSpaceIDs.isEmpty ? "no Space" : window.originSpaceIDs.prefix(3).map { place($0, in: displays) }.joined(separator: " + "))")
                let candidate = window.subrole == "AXStandardWindow" && !window.isMinimized
                let verdict = candidate && (ax.settable || menu?.enabled == true) ? "candidate for --method ax/menu/keys" : "unlikely to go full screen"
                print("    \(verdict)")
            }
            print("")
        }
        if shown == 0 { print("No windows found on the current Space.") }
        return 0
    }

    // MARK: enter / exit

    static func runSingle(_ options: Options, entering: Bool) -> Int32 {
        let spec = options.apps[0]
        let target: FullScreenTarget
        switch resolve(spec, forExit: !entering) {
        case .found(let chosen): target = chosen
        case .failed(let message):
            fputs("fullscreen: \(message)\n", stderr)
            return 1
        }

        let run = Run(test: entering ? "fullscreen-enter" : "fullscreen-exit")
        run.observe("method", options.method.rawValue)
        run.observe("auto-rearrange-spaces", autoRearrangeIsOn() ? "on" : "off")
        run.observe("target", target.label)
        run.observe("target-origin-spaces", target.originSpaceIDs.map(String.init).joined(separator: ","))
        run.log("Captured \(target.label) on \(place(target.originSpaceIDs.first, in: (try? SpaceReader.displays()) ?? []))")
        if autoRearrangeIsOn() { run.log("Warning: Space auto-rearrange is ON; the order may change by itself.") }

        if entering {
            countdown(options.delay, reason: "Entering full screen in \(Int(options.delay.rounded(.up))) s. Switch to another Desktop now to test a window captured earlier.")
        }
        let t = entering
            ? FullScreenProbe.enter(target, method: options.method, focus: options.focus)
            : FullScreenProbe.exit(target, method: options.method, focus: options.focus)
        report(t, number: 1, of: 1, in: run, prefix: entering ? "enter" : "exit")

        run.result.finish(passed: t.succeeded)
        print("")
        printSummary(for: [t], entering: entering)
        if t.succeeded && entering {
            print("The window is still full screen. Return it with: spaceslab fullscreen exit --app \"\(target.appName)\" (stand on its Space first).")
        }
        return save(run)
    }

    // MARK: test

    static func runTest(_ options: Options) -> Int32 {
        // 1. Capture every window before anything changes.
        var targets: [FullScreenTarget] = []
        for spec in options.apps {
            switch resolve(spec, forExit: false) {
            case .found(let chosen):
                if targets.contains(where: { $0.windowID == chosen.windowID || $0.pid == chosen.pid }) {
                    fputs("fullscreen: \(chosen.appName) is listed twice; each app may appear once\n", stderr)
                    return 2
                }
                targets.append(chosen)
            case .failed(let message):
                fputs("fullscreen: \(message)\n", stderr)
                return 1
            }
        }

        let run = Run(test: "fullscreen-order")
        let startDisplays = (try? SpaceReader.displays()) ?? []
        let displayID = FullScreenProbe.homeSpace(ofWindowSpaces: targets[0].originSpaceIDs, in: startDisplays)?
            .display.displayIdentifier
        run.observe("method", options.method.rawValue)
        run.observe("auto-rearrange-spaces", autoRearrangeIsOn() ? "on" : "off")
        run.observe("apps-in-enter-order", targets.map(\.appName).joined(separator: ", "))
        run.observe("targets", targets.map(\.label).joined(separator: " | "))
        run.observe("order-before", orderLine(startDisplays, identifier: displayID))
        run.log("Order before: \(orderLine(startDisplays, identifier: displayID))")
        if autoRearrangeIsOn() { run.log("Warning: Space auto-rearrange is ON; the order may change by itself.") }
        for target in targets {
            run.log("Captured \(target.label) on \(place(target.originSpaceIDs.first, in: startDisplays))")
        }

        countdown(options.delay, reason: "Starting in \(Int(options.delay.rounded(.up))) s. Switch to another Desktop now to test a window captured earlier.")

        // 2. Enter in the given order.
        var entered: [FullScreenTransition] = []
        var allOK = true
        for (n, target) in targets.enumerated() {
            let t = FullScreenProbe.enter(target, method: options.method, focus: options.focus)
            report(t, number: n + 1, of: targets.count, in: run, prefix: "enter-\(n + 1)")
            entered.append(t)
            if !t.succeeded {
                allOK = false
                run.log("Stopping the enter phase: \(target.appName) did not enter full screen.")
                break
            }
        }

        let afterEnters = (try? SpaceReader.displays()) ?? []
        let enteredIDs = entered.filter(\.succeeded).compactMap(\.fullScreenSpaceID)
        let finalDisplay = afterEnters.first { $0.displayIdentifier == (entered.last?.displayIdentifier ?? displayID) } ?? afterEnters.first
        run.observe("order-after-all-enters", orderLine(afterEnters, identifier: finalDisplay?.displayIdentifier))
        run.log("Order after all enters: \(orderLine(afterEnters, identifier: finalDisplay?.displayIdentifier))")
        if let finalDisplay, enteredIDs.count > 1 {
            let resulting = FullScreenProbe.order(of: enteredIDs, in: finalDisplay)
            let namesByID = Dictionary(entered.compactMap { t in t.fullScreenSpaceID.map { ($0, t.target.appName) } },
                                       uniquingKeysWith: { first, _ in first })
            let resultNames = resulting.compactMap { namesByID[$0] }
            let enterNames = entered.filter(\.succeeded).map(\.target.appName)
            let relation = resultNames == enterNames ? "same as the enter order"
                : (resultNames == enterNames.reversed() ? "REVERSED compared with the enter order" : "different from the enter order")
            run.observe("fs-order-in-list", resultNames.joined(separator: " , "))
            run.observe("fs-order-vs-enter-order", relation)
            run.log("Full-screen Spaces in list order: \(resultNames.joined(separator: " , ")) (\(relation))")
        }

        // 3. Exit in reverse order.
        var exited: [FullScreenTransition] = []
        if options.keep {
            run.log("--keep: leaving the windows in full screen.")
        } else {
            let toExit = entered.filter(\.succeeded).reversed()
            for (n, t) in toExit.enumerated() {
                let out = FullScreenProbe.exit(t.target, method: options.method, focus: options.focus)
                report(out, number: n + 1, of: toExit.count, in: run, prefix: "exit-\(n + 1)", originSpaceIDs: t.originSpaceID.map { [$0] } ?? t.target.originSpaceIDs)
                exited.append(out)
                if !out.succeeded {
                    allOK = false
                    run.log("Exit of \(t.target.appName) failed; continuing with the others.")
                }
            }
            let afterExits = (try? SpaceReader.displays()) ?? []
            run.observe("order-after-all-exits", orderLine(afterExits, identifier: finalDisplay?.displayIdentifier))
            run.log("Order after all exits: \(orderLine(afterExits, identifier: finalDisplay?.displayIdentifier))")
            run.observe("current-space-at-end", place(SpaceReader.activeSpaceID(), in: afterExits))
        }

        run.result.finish(passed: allOK && entered.count == targets.count)
        print("")
        printSummary(for: entered, entering: true)
        if !exited.isEmpty { printSummary(for: exited, entering: false) }
        return save(run)
    }

    // MARK: Reporting one transition

    /// Logs a transition and records its observations under `<prefix>-...`.
    static func report(_ t: FullScreenTransition, number: Int, of total: Int, in run: Run, prefix: String,
                       originSpaceIDs: [UInt64] = []) {
        let entering = t.direction == .enter
        func key(_ name: String) -> String { "\(prefix)-\(name)" }
        let beforeDisplay = t.display(t.beforeAll)
        let afterDisplay = t.display(t.afterAll)

        run.log("[\(t.direction.rawValue) \(number)/\(total)] \(t.target.label) via \(t.method.rawValue)")
        run.observe(key("app"), t.target.appName)
        run.observe(key("window"), "\(t.target.windowID)")
        run.observe(key("method"), t.method.rawValue)
        run.observe(key("order-before"), orderLine(t.beforeAll, identifier: t.displayIdentifier))
        run.log("  before: \(orderLine(t.beforeAll, identifier: t.displayIdentifier))")
        if let focus = t.focusNote {
            run.log("  \(focus)")
            run.observe(key("focus"), focus)
        }
        run.log("  current Space before: \(place(t.currentBefore, in: t.beforeAll)); at trigger: \(place(t.currentAtTrigger, in: t.beforeAll))")
        run.observe(key("current-before"), place(t.currentBefore, in: t.beforeAll))
        run.observe(key("current-at-trigger"), place(t.currentAtTrigger, in: t.beforeAll))
        if entering {
            run.log("  window was on: \(place(t.originSpaceID, in: t.beforeAll))")
            run.observe(key("origin"), place(t.originSpaceID, in: t.beforeAll))
            if let origin = t.originSpaceID, let current = t.currentAtTrigger {
                run.observe(key("origin-is-current"), origin == current ? "yes" : "no")
            }
        }

        run.log("  trigger: \(t.triggerDetail.isEmpty ? "-" : t.triggerDetail) (call took \(seconds(t.triggerCallSeconds)))")
        run.observe(key("trigger"), t.triggerDetail)
        run.observe(key("trigger-call-seconds"), seconds(t.triggerCallSeconds))
        run.observe(key("result"), t.succeeded ? "ok" : "failed")

        if let error = t.error {
            run.log("  FAILED: \(error)")
            run.observe(key("error"), error)
            if let afterDisplay { run.log("  last reading: \(SpacesCommand.order(of: afterDisplay))") }
            if let ax = t.axFullScreenAfter { run.observe(key("ax-fullscreen-after"), ax ? "true" : "false") }
            return
        }

        run.observe(key("seconds"), seconds(t.seconds))
        if let ax = t.axFullScreenAfter { run.observe(key("ax-fullscreen-after"), ax ? "true" : "false") }
        if let by = t.matchedBy { run.observe(key("matched-by"), by) }

        if entering {
            run.log("  new Space appeared after \(seconds(t.appearedSeconds)); window owns it after \(seconds(t.seconds)) (matched by \(t.matchedBy ?? "?"))")
            run.observe(key("appeared-seconds"), seconds(t.appearedSeconds))
            run.observe(key("new-space"), place(t.fullScreenSpaceID, in: t.afterAll))
            run.log("  new Space: \(place(t.fullScreenSpaceID, in: t.afterAll)); neighbours: \(t.fullScreenSpaceID.map { neighbours(of: $0, in: t.afterAll) } ?? "-")")
            run.observe(key("neighbours"), t.fullScreenSpaceID.map { neighbours(of: $0, in: t.afterAll) } ?? "-")
            run.log("  placement: \(placementText(t))")
            run.observe(key("placement"), t.placement?.description ?? "unknown")
            run.observe(key("placement-all-matches"), t.placementMatches.map(\.description).joined(separator: ", "))
            if let settled = t.placementSettled {
                run.observe(key("placement-settled"), settled.description)
                if settled != t.placement { run.log("  placement after settling differs: \(settled)") }
            }
            if let from = t.fromSpaceUUID {
                let target = t.fromSpaceID.map { place($0, in: t.afterAll) } ?? "no matching Space"
                run.log("  macOS fromSpace: \"\(from)\" -> \(target)")
                run.observe(key("from-space"), "\(from) -> \(target)")
                if let id = t.fromSpaceID, let origin = t.originSpaceID {
                    run.observe(key("from-space-is-origin"), id == origin ? "yes" : "no")
                }
            } else {
                run.log("  macOS fromSpace: not present in the raw data")
            }
            if !t.rawKeys.isEmpty { run.observe(key("raw-keys"), t.rawKeys.joined(separator: ",")) }
        } else {
            run.log("  full-screen Space \(t.fullScreenSpaceID.map(String.init) ?? "?") gone after \(seconds(t.seconds)); window back on a Desktop after \(seconds(t.returnedSeconds))")
            run.observe(key("fs-space"), place(t.fullScreenSpaceID, in: t.beforeAll))
            run.observe(key("returned-seconds"), seconds(t.returnedSeconds))
            let returned = place(t.returnedSpaceID, in: t.afterAll)
            run.log("  window returned to: \(returned)")
            run.observe(key("returned-to"), returned)
            if let settled = t.returnedSettledSpaceID, settled != t.returnedSpaceID {
                let text = place(settled, in: t.settledAll)
                run.log("  after settling the window is on: \(text)")
                run.observe(key("returned-to-settled"), text)
            }
            if let returnedID = t.returnedSettledSpaceID ?? t.returnedSpaceID {
                if !originSpaceIDs.isEmpty {
                    run.observe(key("returned-to-origin"), originSpaceIDs.contains(returnedID) ? "yes" : "no")
                    run.log("  origin before entering was \(originSpaceIDs.prefix(3).map { place($0, in: t.afterAll) }.joined(separator: ", ")): "
                        + (originSpaceIDs.contains(returnedID) ? "returned to the origin" : "did NOT return to the origin"))
                }
                if let from = t.fromSpaceUUID {
                    let predicted = t.fromSpaceID
                    run.observe(key("from-space"), "\(from) -> \(place(predicted, in: t.beforeAll))")
                    if let predicted {
                        run.observe(key("returned-to-from-space"), predicted == returnedID ? "yes" : "no")
                        run.log("  macOS fromSpace was \(place(predicted, in: t.beforeAll)): " + (predicted == returnedID ? "matches" : "does NOT match"))
                    }
                }
            }
        }

        let settledDisplay = t.display(t.settledAll)
        run.log("  after: \(orderLine(t.afterAll, identifier: t.displayIdentifier))")
        run.observe(key("order-after"), orderLine(t.afterAll, identifier: t.displayIdentifier))
        if let settledDisplay, let afterDisplay, settledDisplay != afterDisplay {
            run.log("  after settling: \(SpacesCommand.order(of: settledDisplay))")
            run.observe(key("order-settled"), SpacesCommand.order(of: settledDisplay))
        }
        if let beforeDisplay, let afterDisplay {
            let diff = describe(FullScreenProbe.diffOrder(before: beforeDisplay, after: afterDisplay), in: afterDisplay, before: beforeDisplay)
            run.log("  change: \(diff)")
            run.observe(key("order-diff"), diff)
        }
        if let currentAfter = t.currentAfter {
            run.log("  current Space after: \(place(currentAfter, in: t.settledAll))")
            run.observe(key("current-after"), place(currentAfter, in: t.settledAll))
        }
    }

    // MARK: Summary and saving

    static func printSummary(for transitions: [FullScreenTransition], entering: Bool) {
        guard !transitions.isEmpty else { return }
        print(entering ? "Summary (enter):" : "Summary (exit):")
        for t in transitions {
            var line = "  \(t.target.appName): "
            if let error = t.error {
                line += "FAILED (\(error))"
            } else if entering {
                line += "placement \(placementText(t)), \(seconds(t.seconds))"
                if let at = t.currentAtTrigger, let origin = t.originSpaceID, at != origin { line += ", triggered while standing on another Space" }
            } else {
                line += "returned to \(place(t.returnedSettledSpaceID ?? t.returnedSpaceID, in: t.settledAll.isEmpty ? t.afterAll : t.settledAll)), \(seconds(t.seconds))"
            }
            print(line)
        }
    }

    static func save(_ run: Run) -> Int32 {
        do {
            let url = try run.result.save()
            print("Saved \(url.path)")
            return run.result.passed == false ? 1 : 0
        } catch {
            fputs("fullscreen: could not save the lab result: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
