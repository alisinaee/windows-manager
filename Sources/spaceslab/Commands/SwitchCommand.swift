import AppKit
import Foundation
import WMCore

enum SwitchCommand {
    static let name = "switch"
    static let help = "Switch Space by swipe, Ctrl+Arrow, Ctrl+number or SkyLight (--probe --to --bench)"

    static let usage = """
        Usage: spaceslab switch --probe
               spaceslab switch --to <position> [--display <n>] [--method <m>] [--stay]
               spaceslab switch --bench [--display <n>] [--method <m>]

          --probe      Read-only. Show the Mission Control shortcuts (enabled or not, key combos), the SkyLight
                       symbols, the Spaces per display and which methods are usable. Posts nothing.
          --to <n>     Switch the display to the n-th Space in Mission Control order (the [n] of `spaceslab spaces`),
                       verify it by polling every 30 ms for up to 3 s, then switch back to where it started.
                       Records "switch-<method>".
          --bench      For each usable method go one Space right and back left, 3 times, and compare timings.
                       Records "switch-bench". Ends on the Space it started on.

        Options:
          --display <n>          Display number as in `spaceslab spaces` (default 1).
          --method <m>           swipe | keys | number | sls. Default for --to: the first usable of swipe, keys, number.
                                 With --bench it limits the run to that method (sls is only tried when asked for
                                 or when everything else is unusable).
          --stay                 With --to: do not switch back afterwards.
          --swipe-variant <v>    auto | legacy | modern (default auto: modern on macOS 27 and later).
          --swipe-invert         Flip the swipe direction sign.
          --sls-plain            sls: call only SLSManagedDisplaySetCurrentSpace (no SLSShowSpaces / SLSHideSpaces).
          --modifier-keys        keys/number: also post separate Ctrl key presses, not only key flags.
          --step-delay <sec>     Pause between repeated steps (default 0.1).
          --no-cursor            Do not move the mouse pointer onto the target display.
          --no-save              Do not write a lab result file.

        --to and --bench change the active Space for real. Do not touch the keyboard or trackpad while they run.
        The sls method changes SkyLight's state and may not repaint the screen; if the screen looks stale
        afterwards, switch by hand (Ctrl+Left / Ctrl+Right or a click in Mission Control).

        """

    struct UsageError: Error {
        let message: String
    }

    struct Options {
        var probe = false
        var bench = false
        var to: Int?
        var display: Int?
        var method: SwitchMethod?
        var stay = false
        var save = true
        var switchOptions = SwitchOptions()
    }

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < args.count else { throw UsageError(message: "\(flag) needs a value") }
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--probe": o.probe = true
            case "--bench": o.bench = true
            case "--to":
                guard let n = Int(try value(arg)), n >= 1 else {
                    throw UsageError(message: "--to needs a position of 1 or more")
                }
                o.to = n
            case "--display":
                guard let n = Int(try value(arg)), n >= 1 else {
                    throw UsageError(message: "--display needs a display number of 1 or more")
                }
                o.display = n
            case "--method":
                let text = try value(arg)
                guard let method = SwitchMethod(rawValue: text) else {
                    throw UsageError(message: "unknown method \(text) (use \(SwitchMethod.allCases.map(\.rawValue).joined(separator: ", ")))")
                }
                o.method = method
            case "--stay": o.stay = true
            case "--swipe-variant":
                let text = try value(arg)
                guard let variant = SwipeVariant(rawValue: text) else {
                    throw UsageError(message: "unknown swipe variant \(text) (use auto, legacy or modern)")
                }
                o.switchOptions.swipeVariant = variant
            case "--swipe-invert": o.switchOptions.invertSwipe = true
            case "--sls-plain": o.switchOptions.slsShowHide = false
            case "--modifier-keys": o.switchOptions.pressModifierKeys = true
            case "--step-delay":
                guard let seconds = Double(try value(arg)), seconds >= 0 else {
                    throw UsageError(message: "--step-delay needs a number of seconds")
                }
                o.switchOptions.stepDelay = seconds
            case "--no-cursor": o.switchOptions.moveCursorToDisplay = false
            case "--no-save": o.save = false
            default:
                throw UsageError(message: "unknown option \(arg)")
            }
            index += 1
        }
        let modes = [o.probe, o.bench, o.to != nil].filter { $0 }.count
        if modes != 1 { throw UsageError(message: "choose exactly one of --probe, --to <n> or --bench") }
        return o
    }

    static func run(_ args: [String]) -> Int32 {
        if args.contains("-h") || args.contains("--help") {
            print(usage, terminator: "")
            return 0
        }
        let options: Options
        do {
            options = try parse(args)
        } catch let error as UsageError {
            fputs("switch: \(error.message)\n\n" + usage, stderr)
            return 2
        } catch {
            fputs("switch: \(error.localizedDescription)\n", stderr)
            return 2
        }
        if options.probe { return probe(options) }
        if let position = options.to { return runTo(position, options) }
        return runBench(options)
    }

    // MARK: Shared output helpers

    private static func log(_ text: String, _ result: inout LabResult) {
        result.step(text)
        print(text)
        fflush(stdout)
    }

    private static func logOutcome(_ outcome: SwitchOutcome, label: String, _ result: inout LabResult) {
        log("\(label): \(outcome.summary)", &result)
        for note in outcome.notes {
            result.step("    \(note)")
            print("    \(note)")
        }
        fflush(stdout)
    }

    private static func seconds(_ value: TimeInterval?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "-"
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    private static func finish(_ result: inout LabResult, passed: Bool?, save: Bool) {
        result.finish(passed: passed)
        guard save else { return }
        do {
            let url = try result.save()
            print("Saved \(url.path)")
        } catch {
            fputs("switch: could not save the lab result: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func name(of display: DisplaySpaces, number: Int) -> String {
        "Display \(number): \(display.displayName ?? display.displayIdentifier)"
    }

    private static func currentSpaceID(of identifier: String) -> UInt64? {
        (try? SpaceReader.displays())?.first { $0.displayIdentifier == identifier }?.currentSpaceID
    }

    /// Display by 1-based number (default 1), with an error message on stderr when it does not exist.
    private static func pickDisplay(_ number: Int?, _ displays: [DisplaySpaces]) -> (number: Int, display: DisplaySpaces)? {
        let n = number ?? 1
        guard n >= 1, n <= displays.count else {
            fputs("switch: display \(n) does not exist (found \(displays.count))\n", stderr)
            return nil
        }
        return (n, displays[n - 1])
    }

    /// Order of Spaces for the lab result: "D1[1]* | FS:Safari[40]".
    private static func order(of display: DisplaySpaces) -> String {
        SpacesCommand.order(of: display)
    }

    private static func recordEnvironment(_ result: inout LabResult, display: DisplaySpaces, number: Int,
                                          options: SwitchOptions) {
        result.observe("display", String(number))
        result.observe("display-identifier", display.displayIdentifier)
        result.observe("spaces-order-before", order(of: display))
        result.observe("accessibility-trusted", String(AXPermission.isTrusted()))
        result.observe("natural-scrolling", String(SpaceSwitcher.naturalScrolling()))
        result.observe("swipe-variant", SpaceSwitcher.resolvedSwipeVariant(options.swipeVariant).rawValue
            + (options.invertSwipe ? " (inverted)" : ""))
        let keys = SymbolicHotKeys.read()
        for id in [SymbolicHotKeys.moveLeftID, SymbolicHotKeys.moveRightID] {
            if let key = keys[id] { result.observe("hotkey-\(id)", "\(key.enabled ? "enabled" : "disabled") \(key.combo)") }
        }
    }

    /// Tries each method in turn until the display is back on `start`. True when it is.
    private static func returnToStart(_ start: UInt64, display: String, order methods: [SwitchMethod],
                                      options: SwitchOptions, _ result: inout LabResult) -> Bool {
        if currentSpaceID(of: display) == start { return true }
        for method in methods {
            let outcome = SpaceSwitcher.switchTo(spaceID: start, onDisplay: display, method: method, options: options)
            logOutcome(outcome, label: "return via \(method.rawValue)", &result)
            if outcome.reached { return true }
            SpaceSwitcher.pause(0.4)
            if currentSpaceID(of: display) == start { return true }
        }
        return currentSpaceID(of: display) == start
    }

    /// The methods to try for getting back: the preferred ones first, then the real input methods, sls only last.
    private static func recoveryOrder(preferred: [SwitchMethod], usable: Set<SwitchMethod>) -> [SwitchMethod] {
        var list = preferred
        for method in [SwitchMethod.keys, .swipe, .number, .sls] where usable.contains(method) && !list.contains(method) {
            list.append(method)
        }
        return list
    }

    // MARK: --probe

    static func probe(_ o: Options) -> Int32 {
        var result = LabResult(test: "switch-probe")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let trusted = AXPermission.isTrusted()
        let natural = SpaceSwitcher.naturalScrolling()
        let variant = SpaceSwitcher.resolvedSwipeVariant(o.switchOptions.swipeVariant)

        print("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        print("Accessibility (needed to post events): \(trusted ? "trusted" : "NOT trusted")")
        print("SkyLight: \(PrivateSymbols.isLoaded ? "loaded" : "NOT loaded (\(PrivateSymbols.loadError ?? "unknown error"))")")
        print("Natural scrolling: \(natural ? "on" : "off")   Swipe variant that would be used: \(variant.rawValue)")
        result.observe("macos", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        result.observe("accessibility-trusted", String(trusted))
        result.observe("skylight-loaded", String(PrivateSymbols.isLoaded))
        result.observe("natural-scrolling", String(natural))
        result.observe("swipe-variant", variant.rawValue)
        result.step("probed system state")

        // Displays
        print("\nDisplays:")
        do {
            let displays = try SpaceReader.displays()
            for (n, display) in displays.enumerated() {
                let position = display.currentSpace.map { $0.index + 1 }
                print("  \(name(of: display, number: n + 1)): \(display.spaces.count) Space(s), "
                    + "current is position \(position.map(String.init) ?? "?")")
                result.observe("display-\(n + 1)", "\(display.displayName ?? display.displayIdentifier): "
                    + "\(display.spaces.count) Spaces, current position \(position.map(String.init) ?? "?")")
            }
            if displays.isEmpty { print("  none reported") }
        } catch {
            print("  cannot read: \(error.localizedDescription)")
            result.observe("displays", "unreadable: \(error.localizedDescription)")
        }

        // Hotkeys
        let keys = SymbolicHotKeys.read()
        print("\nMission Control shortcuts (com.apple.symbolichotkeys, AppleSymbolicHotKeys):")
        print("  " + "id".padding(toLength: 4, withPad: " ", startingAt: 0)
            + "name".padding(toLength: 24, withPad: " ", startingAt: 0)
            + "state".padding(toLength: 10, withPad: " ", startingAt: 0) + "key combo")
        var enabledDesktops: [Int] = []
        for id in SymbolicHotKeys.relevantIDs {
            guard let key = keys[id] else { continue }
            if id >= 118, key.enabled, key.isUsable { enabledDesktops.append(id - 117) }
            // Show the two Move keys and every Desktop shortcut that is on, has a key, or sits in the plist.
            if id >= 118 && !key.enabled && !key.inPlist { continue }
            let mods = key.modifiers.map { "0x" + String($0, radix: 16) } ?? "-"
            let detail = key.keyCode == nil ? "none"
                : "\(key.combo) (keycode \(key.keyCode ?? -1), flags \(mods))"
            let source = key.inPlist ? (key.comboIsDefault ? "plist entry, default combo" : "plist entry")
                : "not in plist, macOS default"
            print("  " + String(id).padding(toLength: 4, withPad: " ", startingAt: 0)
                + key.name.padding(toLength: 24, withPad: " ", startingAt: 0)
                + (key.enabled ? "enabled" : "disabled").padding(toLength: 10, withPad: " ", startingAt: 0)
                + detail + "   [" + source + "]")
            result.observe("hotkey-\(id)", "\(key.enabled ? "enabled" : "disabled"); \(detail); \(source)")
        }
        result.observe("desktop-shortcuts-usable", enabledDesktops.isEmpty ? "none" : "Desktop " + SpaceSwitcher.rangeText(enabledDesktops))
        print("  Desktop shortcuts usable: " + (enabledDesktops.isEmpty ? "none"
            : "Desktop " + SpaceSwitcher.rangeText(enabledDesktops)))

        // Symbols
        print("\nSkyLight symbols:")
        for symbol in ["SLSMainConnectionID", "SLSManagedDisplaySetCurrentSpace", "SLSShowSpaces", "SLSHideSpaces",
                       "SLSCopyManagedDisplayForSpace"] {
            let present = PrivateSymbols.exists(symbol)
            print("  \(present ? "yes" : "NO ")  \(symbol)")
            result.observe("symbol-\(symbol)", present ? "present" : "missing")
        }

        // Methods
        let methods = SpaceSwitcher.availableMethods()
        print("\nMethods:")
        for item in methods {
            print("  \(item.method.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))"
                + "\(item.usable ? "usable    " : "not usable")  \(item.reason)")
            result.observe("method-\(item.method.rawValue)", "\(item.usable ? "usable" : "not usable"): \(item.reason)")
        }
        result.step("listed methods")

        finish(&result, passed: nil, save: o.save)
        return methods.contains { $0.usable } ? 0 : 1
    }

    // MARK: --to

    static func runTo(_ position: Int, _ o: Options) -> Int32 {
        let displays: [DisplaySpaces]
        do {
            displays = try SpaceReader.displays()
        } catch {
            fputs("switch: \(error.localizedDescription)\n", stderr)
            return 1
        }
        guard let (number, display) = pickDisplay(o.display, displays) else { return 2 }
        guard let start = display.currentSpace else {
            fputs("switch: \(name(of: display, number: number)) reports no current Space\n", stderr)
            return 1
        }
        guard position <= display.spaces.count else {
            fputs("switch: \(name(of: display, number: number)) has only \(display.spaces.count) Space(s)\n", stderr)
            return 2
        }
        let target = display.spaces[position - 1]
        if target.id == start.id {
            fputs("switch: position \(position) is already the current Space; pick another one\n", stderr)
            return 2
        }

        let availability = SpaceSwitcher.availableMethods()
        let usable = Set(availability.filter(\.usable).map(\.method))
        let method: SwitchMethod
        if let chosen = o.method {
            method = chosen
        } else if let first = [SwitchMethod.swipe, .keys, .number].first(where: { usable.contains($0) }) {
            method = first
        } else {
            fputs("switch: no usable method; run `spaceslab switch --probe` to see why\n", stderr)
            return 1
        }

        var result = LabResult(test: "switch-\(method.rawValue)")
        recordEnvironment(&result, display: display, number: number, options: o.switchOptions)
        result.observe("method", method.rawValue)
        result.observe("start-space-id", String(start.id))
        result.observe("start-position", String(start.index + 1))
        result.observe("target-space-id", String(target.id))
        result.observe("target-position", String(position))
        result.observe("target-kind", String(describing: target.kind))
        result.observe("method-availability", availability.first { $0.method == method }
            .map { ($0.usable ? "usable: " : "not usable: ") + $0.reason } ?? "unknown")

        log("\(name(of: display, number: number)): switching position \(start.index + 1) -> \(position) by \(method.rawValue). "
            + "Hands off the keyboard and trackpad.", &result)
        let outcome = SpaceSwitcher.switchTo(spaceID: target.id, onDisplay: display.displayIdentifier,
                                             method: method, options: o.switchOptions)
        logOutcome(outcome, label: "switch", &result)
        result.observe("steps", "\(outcome.stepCount) \(outcome.direction.rawValue)")
        result.observe("attempted", String(outcome.attempted))
        result.observe("reached", String(outcome.reached))
        result.observe("elapsed-seconds", seconds(outcome.elapsed))
        result.observe("first-change-seconds", seconds(outcome.firstChange))
        result.observe("final-space-id", outcome.finalSpaceID.map(String.init) ?? "-")
        result.observe("notifications", String(outcome.notificationCount))
        result.observe("first-notification-seconds", seconds(outcome.notificationDelay))
        result.observe("screen", outcome.repaint?.rawValue ?? "not checked")
        if let error = outcome.error { result.observe("error", error) }

        var backOK = true
        if !o.stay {
            SpaceSwitcher.pause(0.5)
            let tryOrder = recoveryOrder(preferred: [method], usable: usable)
            let before = Date()
            backOK = returnToStart(start.id, display: display.displayIdentifier, order: tryOrder,
                                   options: o.switchOptions, &result)
            result.observe("returned-to-start", String(backOK))
            result.observe("return-seconds", String(format: "%.3f", Date().timeIntervalSince(before)))
            log(backOK ? "Back on the starting Space." : "WARNING: could not return to the starting Space (position \(start.index + 1)); switch back by hand.",
                &result)
        }
        if let after = (try? SpaceReader.displays())?.first(where: { $0.displayIdentifier == display.displayIdentifier }) {
            result.observe("spaces-order-after", order(of: after))
        }

        finish(&result, passed: outcome.worked, save: o.save)
        return outcome.worked && backOK ? 0 : 1
    }

    // MARK: --bench

    static func runBench(_ o: Options) -> Int32 {
        let displays: [DisplaySpaces]
        do {
            displays = try SpaceReader.displays()
        } catch {
            fputs("switch: \(error.localizedDescription)\n", stderr)
            return 1
        }
        guard let (number, display) = pickDisplay(o.display, displays) else { return 2 }
        guard let start = display.currentSpace else {
            fputs("switch: \(name(of: display, number: number)) reports no current Space\n", stderr)
            return 1
        }
        guard display.spaces.count >= 2 else {
            fputs("switch: \(name(of: display, number: number)) has only one Space; the bench needs at least two\n", stderr)
            return 1
        }

        // One step right when there is a Space on the right, otherwise one step left (and back).
        let goRight = start.index + 1 < display.spaces.count
        let neighbour = display.spaces[goRight ? start.index + 1 : start.index - 1]

        let availability = SpaceSwitcher.availableMethods()
        let usable = Set(availability.filter(\.usable).map(\.method))
        var methods: [SwitchMethod]
        if let only = o.method {
            methods = [only]
        } else {
            // SkyLight is a state-only experiment; leave it out unless nothing else can be used.
            methods = [SwitchMethod.swipe, .keys, .number].filter { usable.contains($0) }
            if methods.isEmpty && usable.contains(.sls) { methods = [.sls] }
        }
        if methods.isEmpty {
            fputs("switch: no usable method; run `spaceslab switch --probe` to see why\n", stderr)
            return 1
        }

        var result = LabResult(test: "switch-bench")
        recordEnvironment(&result, display: display, number: number, options: o.switchOptions)
        result.observe("start-space-id", String(start.id))
        result.observe("start-position", String(start.index + 1))
        result.observe("neighbour-space-id", String(neighbour.id))
        result.observe("neighbour-position", String(neighbour.index + 1))
        result.observe("first-direction", goRight ? "right" : "left")
        result.observe("methods-tried", methods.map(\.rawValue).joined(separator: ", "))

        log("\(name(of: display, number: number)): bench of \(methods.map(\.rawValue).joined(separator: ", ")), "
            + "3 rounds each, position \(start.index + 1) <-> \(neighbour.index + 1). Hands off the keyboard and trackpad.", &result)

        let pauseBetween = 0.5
        var working: [SwitchMethod] = []
        var table: [(method: SwitchMethod, reached: String, median: Double?, min: Double?, max: Double?, note: String, screen: String)] = []
        var stuck = false

        for method in methods {
            if stuck { break }
            var outcomes: [SwitchOutcome] = []
            var skipped: String?

            for round in 1...3 {
                let there = SpaceSwitcher.switchTo(spaceID: neighbour.id, onDisplay: display.displayIdentifier,
                                                   method: method, options: o.switchOptions)
                logOutcome(there, label: "\(method.rawValue) round \(round) \(goRight ? "right" : "left")", &result)
                if !there.attempted {
                    skipped = there.error ?? "not attempted"
                    break
                }
                outcomes.append(there)
                SpaceSwitcher.pause(pauseBetween)

                // If nothing moved there is no way back to measure; otherwise go back to the start.
                if currentSpaceID(of: display.displayIdentifier) != start.id {
                    let back = SpaceSwitcher.switchTo(spaceID: start.id, onDisplay: display.displayIdentifier,
                                                      method: method, options: o.switchOptions)
                    logOutcome(back, label: "\(method.rawValue) round \(round) \(goRight ? "left" : "right")", &result)
                    if back.attempted { outcomes.append(back) }
                    SpaceSwitcher.pause(pauseBetween)
                } else if !there.reached {
                    result.step("\(method.rawValue) round \(round): still on the starting Space, nothing to go back from")
                }

                if currentSpaceID(of: display.displayIdentifier) != start.id {
                    let tryOrder = recoveryOrder(preferred: [method], usable: usable)
                    if !returnToStart(start.id, display: display.displayIdentifier, order: tryOrder,
                                      options: o.switchOptions, &result) {
                        stuck = true
                        break
                    }
                    SpaceSwitcher.pause(pauseBetween)
                    break   // the method did not get back by itself; stop its rounds here
                }
            }

            // Statistics for this method.
            let tried = outcomes.filter { $0.attempted && $0.stepCount > 0 }
            let reached = tried.filter(\.reached)
            let times = reached.compactMap(\.elapsed)
            let firstChanges = tried.compactMap(\.firstChange)
            let notified = tried.filter { $0.notificationCount > 0 }.count
            let painted = tried.filter { $0.repaint == .painted }.count
            let stale = tried.filter { $0.repaint == .stale }.count
            let unknown = tried.filter { $0.reached && ($0.repaint ?? .unknown) == .unknown }.count
            let key = method.rawValue
            if let skipped {
                result.observe("\(key)-skipped", skipped)
                result.step("\(key) skipped: \(skipped)")
            }
            result.observe("\(key)-switches-reached", "\(reached.count)/\(tried.count)")
            result.observe("\(key)-time-median-seconds", seconds(median(times)))
            result.observe("\(key)-time-min-seconds", seconds(times.min()))
            result.observe("\(key)-time-max-seconds", seconds(times.max()))
            result.observe("\(key)-first-change-median-seconds", seconds(median(firstChanges)))
            result.observe("\(key)-with-notification", "\(notified)/\(tried.count)")
            result.observe("\(key)-screen", "painted \(painted), stale \(stale), unknown \(unknown)")
            result.observe("\(key)-landed-elsewhere", String(tried.filter { !$0.reached && $0.finalSpaceID != $0.startSpaceID }.count))
            let works = !tried.isEmpty && tried.allSatisfy(\.worked)
            result.observe("\(key)-works", String(works))
            if works { working.append(method) }
            table.append((method, "\(reached.count)/\(tried.count)", median(times), times.min(), times.max(),
                          skipped.map { "skipped: \($0)" } ?? "\(notified)/\(tried.count) notified",
                          "painted \(painted), stale \(stale), unknown \(unknown)"))
            SpaceSwitcher.pause(pauseBetween)
        }

        // Make sure we end where we started.
        let tryOrder = recoveryOrder(preferred: working, usable: usable)
        let backOK = returnToStart(start.id, display: display.displayIdentifier, order: tryOrder,
                                   options: o.switchOptions, &result)
        result.observe("returned-to-start", String(backOK))
        log(backOK ? "Back on the starting Space." : "WARNING: could not return to the starting Space (position \(start.index + 1)); switch back by hand.",
            &result)
        if let after = (try? SpaceReader.displays())?.first(where: { $0.displayIdentifier == display.displayIdentifier }) {
            result.observe("spaces-order-after", order(of: after))
        }

        let fastest = table.filter { working.contains($0.method) && $0.median != nil }
            .min { ($0.median ?? .infinity) < ($1.median ?? .infinity) }?.method
        result.observe("working-methods", working.isEmpty ? "none" : working.map(\.rawValue).joined(separator: ", "))
        result.observe("fastest-working-method", fastest?.rawValue ?? "none")

        print("\nMethod   Reached  Median     Min        Max        Notification     Screen")
        for row in table {
            func cell(_ value: Double?) -> String { (value.map { String(format: "%.3f s", $0) } ?? "-").padding(toLength: 10, withPad: " ", startingAt: 0) }
            print(row.method.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
                + row.reached.padding(toLength: 9, withPad: " ", startingAt: 0)
                + cell(row.median) + " " + cell(row.min) + " " + cell(row.max) + " "
                + row.note.padding(toLength: 16, withPad: " ", startingAt: 0) + " " + row.screen)
        }

        let passed = !working.isEmpty && backOK
        finish(&result, passed: passed, save: o.save)
        return passed ? 0 : 1
    }
}
