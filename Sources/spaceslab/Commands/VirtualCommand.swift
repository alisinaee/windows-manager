import AppKit
import Foundation
import WMCore

/// Probes for "Virtual desktops" mode: the app keeps its own workspaces instead of macOS Spaces.
enum VirtualCommand {
    static let name = "virtual"
    static let help = "Try Virtual (own workspaces) mode: --probe, hide-test, park-test, trackpad"

    static let usage = """
        Usage: spaceslab virtual --probe [--save]
               spaceslab virtual hide-test --app <name> [--repeat 5]
               spaceslab virtual park-test --app <name> [--corner br|bl]
               spaceslab virtual trackpad [--seconds 10]

          --probe      Read-only: Stage Manager state, Accessibility, displays, whether MultitouchSupport loads
                       and how many multitouch devices it lists. Nothing is moved or hidden.
          hide-test    Hides and unhides every window of one app with NSRunningApplication.hide()/unhide(),
                       --repeat times, and times when the app reports hidden and its windows leave and
                       return in the window list. Checks that frames are unchanged. The app vanishes briefly.
                       Saves "virtual-hide".
          park-test    Moves the app's front window to the bottom-right (br) or bottom-left (bl) corner of
                       its screen, leaving 1 px visible, measures where macOS let it go, then moves it back.
                       Without --corner the corner that does not touch another display is chosen.
                       Saves "virtual-park". Needs Accessibility permission.
          trackpad     Reads raw trackpad touches for --seconds and prints finger counts and detected
                       3-finger horizontal swipes. macOS still performs its own swipe at the same time.
                       Saves "virtual-trackpad".

        Every result records the Stage Manager state (it is ON or off on this Mac; it can change
        hide and park behaviour). Ctrl+C during a test restores what was changed and still saves the result.

        """

    static func run(_ args: [String]) -> Int32 {
        guard let first = args.first else {
            fputs(usage, stderr)
            return 2
        }
        let rest = Array(args.dropFirst())
        switch first {
        case "-h", "--help", "help":
            print(usage, terminator: "")
            return 0
        case "--probe":
            return probe(rest)
        case "hide-test":
            return hideTest(rest)
        case "park-test":
            return parkTest(rest)
        case "trackpad":
            return trackpad(rest)
        default:
            fputs("virtual: unknown option or test \(first)\n\n" + usage, stderr)
            return 2
        }
    }

    // MARK: Option parsing

    struct UsageError: Error {
        var message: String
    }

    struct Parsed {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var help = false
    }

    /// `--name value` and `--name=value` for names in `values`, bare `--name` for names in `flags`.
    static func parse(_ args: [String], values: Set<String>, flags: Set<String> = []) throws -> Parsed {
        var parsed = Parsed()
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg == "-h" || arg == "--help" {
                parsed.help = true
                continue
            }
            let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            if flags.contains(key), parts.count == 1 {
                parsed.flags.insert(key)
            } else if values.contains(key) {
                if parts.count == 2 {
                    parsed.values[key] = String(parts[1])
                } else if index < args.count {
                    parsed.values[key] = args[index]
                    index += 1
                } else {
                    throw UsageError(message: "\(key) needs a value")
                }
            } else {
                throw UsageError(message: "unknown option \(arg)")
            }
        }
        return parsed
    }

    // MARK: Ctrl+C

    /// Turns Ctrl+C into a flag the experiments check between steps, so they can restore and save.
    enum Interrupt {
        static var requested = false
        private static var source: DispatchSourceSignal?

        static func install() {
            requested = false
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler { requested = true }
            source.resume()
            Interrupt.source = source
        }
    }

    // MARK: Shared helpers

    private static func ms(_ seconds: TimeInterval?) -> String {
        seconds.map { String(format: "%.0f", $0 * 1000) } ?? "never"
    }

    /// "min 40 / avg 55 / max 70 ms (seen 5 of 5)"
    static func stats(_ values: [TimeInterval?]) -> String {
        let seen = values.compactMap { $0 }.map { $0 * 1000 }
        guard !seen.isEmpty else { return "never seen (0 of \(values.count))" }
        let average = seen.reduce(0, +) / Double(seen.count)
        return String(format: "min %.0f / avg %.0f / max %.0f ms (seen %d of %d)",
                      seen.min() ?? 0, average, seen.max() ?? 0, seen.count, values.count)
    }

    private static func rect(_ r: CGRect) -> String {
        "\(Int(r.width.rounded()))x\(Int(r.height.rounded())) at (\(Int(r.minX.rounded())), \(Int(r.minY.rounded())))"
    }

    private static func point(_ p: CGPoint) -> String {
        "(\(Int(p.x.rounded())), \(Int(p.y.rounded())))"
    }

    private static func frontmostName() -> String {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.localizedName ?? app?.bundleIdentifier ?? "unknown"
    }

    /// Facts that every virtual-mode result records, Stage Manager first.
    private static func recordEnvironment(_ result: inout LabResult) {
        let stage = StageManagerState.read()
        result.observe("stage-manager", stage.summary)
        for key in stage.settings.keys.sorted() {
            result.observe("stage-manager-\(key)", stage.settings[key] ?? "")
        }
        result.observe("accessibility-trusted", String(AXPermission.isTrusted()))

        let spans = CFPreferencesCopyAppValue("spans-displays" as CFString, "com.apple.spaces" as CFString) as? NSNumber
        result.observe("displays-have-separate-spaces", spans.map {
            $0.boolValue ? "no (spans-displays = 1)" : "yes (spans-displays = 0)"
        } ?? "yes (spans-displays not set, macOS default)")

        let screens = CornerParker.screenFrames()
        result.observe("screens", String(screens.count))
        for (i, frame) in screens.enumerated() { result.observe("screen-\(i + 1)-frame", rect(frame)) }
        result.observe("frontmost-app-at-start", frontmostName())
        result.step("Stage Manager is \(stage.summary); \(screens.count) screen(s); "
            + "Accessibility \(AXPermission.isTrusted() ? "trusted" : "NOT trusted")")
    }

    /// Saves the result and returns the exit code: 1 when the verdict is "failed", otherwise 0.
    private static func finish(_ result: inout LabResult, passed: Bool?) -> Int32 {
        result.finish(passed: passed)
        let verdict = passed.map { $0 ? "PASS" : "FAIL" } ?? "no verdict (observations only)"
        do {
            let url = try result.save()
            print("\nResult: \(verdict)\nSaved \(url.path)")
        } catch {
            fputs("virtual: could not save the lab result: \(error.localizedDescription)\n", stderr)
            return 1
        }
        return passed == false ? 1 : 0
    }

    /// Prints a line now and records it as a step.
    private static func say(_ text: String, into result: inout LabResult) {
        print(text)
        fflush(stdout)
        result.step(text)
    }

    /// A running regular app that matches `query`, or an explanation. The first match wins.
    private static func resolveApp(_ query: String) -> (app: NSRunningApplication?, note: String?, error: String?) {
        let matches = AXWindows.runningApps(matching: query).filter { $0.activationPolicy == .regular }
        guard let app = matches.first else {
            let names = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
                .compactMap(\.localizedName).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return (nil, nil, "no running app (with a Dock icon) matches \"\(query)\". Running apps: \(names.joined(separator: ", "))")
        }
        let note = matches.count > 1
            ? "\(matches.count) apps match \"\(query)\"; using \(app.localizedName ?? "?") (pid \(app.processIdentifier))" : nil
        return (app, note, nil)
    }

    // MARK: --probe

    static func probe(_ args: [String]) -> Int32 {
        let parsed: Parsed
        do {
            parsed = try parse(args, values: [], flags: ["--save"])
        } catch let error as UsageError {
            fputs("virtual: \(error.message)\n\n" + usage, stderr)
            return 2
        } catch {
            return 2
        }
        if parsed.help {
            print(usage, terminator: "")
            return 0
        }

        var result = LabResult(test: "virtual-probe")
        recordEnvironment(&result)
        let stage = StageManagerState.read()
        let trusted = AXPermission.isTrusted()
        let touch = TrackpadReader.probe()

        print("macOS:           \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Stage Manager:   \(stage.summary)")
        if stage.isOn {
            print("  Stage Manager is ON: hide and park results can differ from the same test with it off.")
        }
        for key in stage.settings.keys.sorted() { print("  com.apple.WindowManager \(key) = \(stage.settings[key] ?? "")") }
        print("Accessibility:   " + (trusted ? "trusted" : "NOT trusted (park-test needs it; hide-test works with fewer signals)"))
        print("Displays:        \(result.observations["screens"] ?? "?"); separate Spaces per display: "
            + (result.observations["displays-have-separate-spaces"] ?? "?"))
        for i in 0..<(Int(result.observations["screens"] ?? "0") ?? 0) {
            print("  screen \(i + 1): \(result.observations["screen-\(i + 1)-frame"] ?? "?")")
        }

        print("")
        print("MultitouchSupport: " + (touch.loaded ? "loaded" : "NOT loaded (\(touch.loadError ?? "unknown error"))"))
        for name in TrackpadReader.requiredSymbols {
            print("  \((touch.symbols[name] ?? false) ? "yes" : "NO ")  \(name)")
        }
        for name in TrackpadReader.optionalSymbols {
            print("  \((touch.symbols[name] ?? false) ? "yes" : "no ")  \(name) (optional)")
        }
        print("Multitouch devices: \(touch.devices.count)   (assumed MTTouch record size: \(touch.touchStride) bytes)")
        for device in touch.devices {
            var line = "  [\(device.index)]"
            if let builtIn = device.isBuiltIn { line += builtIn ? " built-in" : " external" }
            if let family = device.familyID { line += ", family \(family)" }
            if let w = device.sensorWidth, let h = device.sensorHeight, w > 0, h > 0 {
                line += String(format: ", sensor %.0f x %.0f mm", Double(w) / 100, Double(h) / 100)
            }
            if let id = device.deviceID { line += ", id \(id)" }
            print(line)
        }

        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        print("")
        print("Apps you can pass to --app: \(apps.joined(separator: ", "))")

        result.observe("multitouch-loaded", String(touch.loaded))
        if let error = touch.loadError { result.observe("multitouch-load-error", error) }
        result.observe("multitouch-device-count", String(touch.devices.count))
        result.observe("multitouch-touch-stride", String(touch.touchStride))
        for name in TrackpadReader.requiredSymbols + TrackpadReader.optionalSymbols {
            result.observe("symbol-\(name)", String(touch.symbols[name] ?? false))
        }
        for device in touch.devices {
            result.observe("multitouch-device-\(device.index)",
                           "builtIn=\(device.isBuiltIn.map(String.init) ?? "?") family=\(device.familyID.map(String.init) ?? "?") "
                           + "sensor=\(device.sensorWidth.map(String.init) ?? "?")x\(device.sensorHeight.map(String.init) ?? "?")")
        }

        if parsed.flags.contains("--save") {
            return finish(&result, passed: nil)
        }
        return touch.loaded ? 0 : 1
    }

    // MARK: hide-test

    static func hideTest(_ args: [String]) -> Int32 {
        let parsed: Parsed
        do {
            parsed = try parse(args, values: ["--app", "--repeat"])
        } catch let error as UsageError {
            fputs("virtual hide-test: \(error.message)\n\n" + usage, stderr)
            return 2
        } catch {
            return 2
        }
        if parsed.help {
            print(usage, terminator: "")
            return 0
        }
        guard let query = parsed.values["--app"], !query.isEmpty else {
            fputs("virtual hide-test: --app <name> is required\n\n" + usage, stderr)
            return 2
        }
        var repeatCount = 5
        if let text = parsed.values["--repeat"] {
            guard let n = Int(text), (1...50).contains(n) else {
                fputs("virtual hide-test: --repeat must be a number from 1 to 50\n", stderr)
                return 2
            }
            repeatCount = n
        }

        var result = LabResult(test: "virtual-hide")
        recordEnvironment(&result)
        result.observe("app-query", query)
        result.observe("repeat", String(repeatCount))

        let resolved = resolveApp(query)
        guard let app = resolved.app else {
            let message = resolved.error ?? "app not found"
            fputs("virtual hide-test: \(message)\n", stderr)
            result.observe("error", message)
            return finish(&result, passed: false)
        }
        if let problem = AppHider.problem(with: app) {
            fputs("virtual hide-test: cannot hide \(app.localizedName ?? query): \(problem)\n", stderr)
            result.observe("error", problem)
            return finish(&result, passed: false)
        }

        Interrupt.install()
        let appName = app.localizedName ?? query
        if let note = resolved.note { say(note, into: &result) }
        if StageManagerState.read().isOn {
            say("Stage Manager is ON: hiding behaves differently from the same test with it off.", into: &result)
        }
        if !AXPermission.isTrusted() {
            say("Accessibility is not granted: AXHidden and AX frames are skipped; isHidden and the window list still work.",
                into: &result)
        }
        say("Hiding and unhiding \(appName) \(repeatCount) time(s). It disappears for a moment each time; Ctrl+C unhides it.",
            into: &result)

        let report = AppHider.test(app: app, repeatCount: repeatCount, shouldAbort: { Interrupt.requested },
                                   log: { text in
                                       print("  " + text)
                                       fflush(stdout)
                                       result.step(text)
                                   })

        let cycles = report.cycles
        result.observe("app", report.appName)
        if let bundle = report.bundleID { result.observe("bundle-id", bundle) }
        result.observe("pid", String(report.pid))
        result.observe("activation-policy", report.activationPolicy)
        result.observe("cycles-run", "\(cycles.count) of \(repeatCount)")
        result.observe("cycles-succeeded", String(cycles.filter(\.succeeded).count))
        result.observe("windows-tracked", cycles.map { String($0.windowsBefore) }.joined(separator: ","))
        result.observe("hide-accepted", cycles.map { String($0.hideAccepted) }.joined(separator: ","))
        result.observe("unhide-accepted", cycles.map { String($0.unhideAccepted) }.joined(separator: ","))
        result.observe("hide-call-time", stats(cycles.map { $0.hideCallSeconds }))
        result.observe("hidden-flag-time", stats(cycles.map(\.hiddenFlagAfter)))
        result.observe("ax-hidden-time", stats(cycles.map(\.axHiddenAfter)))
        result.observe("first-window-gone-time", stats(cycles.map(\.firstWindowGoneAfter)))
        result.observe("all-windows-gone-time", stats(cycles.map(\.allWindowsGoneAfter)))
        result.observe("unhide-call-time", stats(cycles.map { $0.unhideCallSeconds }))
        result.observe("shown-flag-time", stats(cycles.map(\.shownFlagAfter)))
        result.observe("ax-shown-time", stats(cycles.map(\.axShownAfter)))
        result.observe("first-window-back-time", stats(cycles.map(\.firstWindowBackAfter)))
        result.observe("all-windows-back-time", stats(cycles.map(\.allWindowsBackAfter)))

        let stillOn = cycles.flatMap(\.windowsStillOnScreen)
        result.observe("windows-still-on-screen-after-hide", stillOn.isEmpty ? "none" : Set(stillOn).sorted().map(String.init).joined(separator: ","))
        let missing = cycles.flatMap(\.windowsMissingAfterUnhide)
        result.observe("windows-missing-after-unhide", missing.isEmpty ? "none" : Set(missing).sorted().map(String.init).joined(separator: ","))
        let differences = cycles.flatMap(\.frameDifferences)
        result.observe("frames-unchanged", differences.isEmpty ? "yes" : "NO (\(differences.count) difference(s))")
        for (i, d) in differences.prefix(5).enumerated() {
            result.observe("frame-difference-\(i + 1)",
                           "window \(d.windowID) [\(d.source)] before \(rect(d.before)), after \(d.after.map(rect) ?? "missing")")
        }
        result.observe("frontmost-before", report.frontmostBefore ?? "unknown")
        result.observe("frontmost-after-hide", cycles.first?.frontmostAfterHide ?? "n/a")
        result.observe("frontmost-after-unhide", cycles.first?.frontmostAfterUnhide ?? "n/a")
        result.observe("frontmost-restored", report.frontmostRestored.map(String.init) ?? "n/a")
        result.observe("safety-unhide-needed", String(report.neededSafetyUnhide))
        if report.interrupted { result.observe("interrupted", "true") }

        for (i, c) in cycles.enumerated() {
            result.observe("cycle-\(i + 1)",
                "hide ok=\(c.hideAccepted) flag=\(ms(c.hiddenFlagAfter))ms ax=\(ms(c.axHiddenAfter))ms gone=\(ms(c.allWindowsGoneAfter))ms | "
                + "unhide ok=\(c.unhideAccepted) flag=\(ms(c.shownFlagAfter))ms ax=\(ms(c.axShownAfter))ms back=\(ms(c.allWindowsBackAfter))ms | "
                + "frame differences \(c.frameDifferences.count)")
        }

        print("")
        print("Summary for \(report.appName) (\(cycles.count) cycle(s), \(cycles.filter(\.succeeded).count) fully clean):")
        print("  app reports hidden after      \(stats(cycles.map(\.hiddenFlagAfter)))")
        print("  windows gone after            \(stats(cycles.map(\.allWindowsGoneAfter)))")
        print("  app reports shown after       \(stats(cycles.map(\.shownFlagAfter)))")
        print("  windows back after            \(stats(cycles.map(\.allWindowsBackAfter)))")
        print("  frames unchanged:             \(differences.isEmpty ? "yes" : "NO")")
        print("  focus after the test:         \(frontmostName()) (was \(report.frontmostBefore ?? "?"); restored: \(report.frontmostRestored.map(String.init) ?? "n/a"))")

        // Verdict: every cycle clean. With no visible windows nothing could be verified.
        let verified = cycles.contains { $0.windowsBefore > 0 }
        var passed: Bool? = !report.interrupted && cycles.count == repeatCount && cycles.allSatisfy(\.succeeded)
        if passed == true && !verified {
            result.observe("note", "the app had no visible windows, so window disappearance could not be checked")
            passed = nil
        }
        return finish(&result, passed: passed)
    }

    // MARK: park-test

    static func parkTest(_ args: [String]) -> Int32 {
        let parsed: Parsed
        do {
            parsed = try parse(args, values: ["--app", "--corner"])
        } catch let error as UsageError {
            fputs("virtual park-test: \(error.message)\n\n" + usage, stderr)
            return 2
        } catch {
            return 2
        }
        if parsed.help {
            print(usage, terminator: "")
            return 0
        }
        guard let query = parsed.values["--app"], !query.isEmpty else {
            fputs("virtual park-test: --app <name> is required\n\n" + usage, stderr)
            return 2
        }
        var corner: ParkCorner?
        if let text = parsed.values["--corner"] {
            guard let value = ParkCorner(rawValue: text.lowercased()) else {
                fputs("virtual park-test: --corner must be br or bl\n", stderr)
                return 2
            }
            corner = value
        }

        var result = LabResult(test: "virtual-park")
        recordEnvironment(&result)
        result.observe("app-query", query)
        result.observe("corner-requested", corner?.rawValue ?? "auto")

        func fail(_ message: String) -> Int32 {
            fputs("virtual park-test: \(message)\n", stderr)
            result.observe("error", message)
            return finish(&result, passed: false)
        }

        guard AXPermission.isTrusted() else {
            return fail("Accessibility permission is needed to move windows. Grant it to your terminal app in "
                + "System Settings > Privacy & Security > Accessibility, then run again.")
        }
        let resolved = resolveApp(query)
        guard let app = resolved.app else { return fail(resolved.error ?? "app not found") }

        // First standard-looking window that a person can see now.
        let visibleIDs = Set(WindowListReader.visibleWindows(pid: app.processIdentifier, minSide: 100).map(\.windowID))
        var chosen: (element: AXUIElement, id: UInt32)?
        for element in AXWindows.windows(of: app) {
            guard let id = AXWindows.windowID(of: element), visibleIDs.contains(id),
                  !AXWindows.isMinimized(element), !AXWindows.isFullScreen(element) else { continue }
            chosen = (element, id)
            break
        }
        guard let window = chosen else {
            return fail("\(app.localizedName ?? query) has no visible, non-minimized, non-full-screen window on the current Space")
        }

        Interrupt.install()
        let appName = app.localizedName ?? query
        let title = AXWindows.title(of: window.element)
        result.observe("app", appName)
        result.observe("pid", String(app.processIdentifier))
        result.observe("window-id", String(window.id))
        if !title.isEmpty { result.observe("window-title", title) }
        if let note = resolved.note { say(note, into: &result) }
        if StageManagerState.read().isOn {
            say("Stage Manager is ON: parking behaves differently from the same test with it off.", into: &result)
        }
        say("Moving the front window of \(appName) to a screen corner and back. Ctrl+C puts it back.", into: &result)

        let report: ParkReport
        do {
            report = try CornerParker.parkAndRestore(
                window: window.element, windowID: window.id, corner: corner,
                shouldAbort: { Interrupt.requested },
                log: { text in
                    print("  " + text)
                    fflush(stdout)
                    result.step(text)
                })
        } catch {
            return fail("could not run the park test: \(error.localizedDescription)")
        }

        result.observe("corner-used", report.corner.rawValue)
        result.observe("original-frame", rect(report.originalFrame))
        result.observe("screen-frame", rect(report.screenFrame))
        result.observe("requested-top-left", point(report.requestedOrigin))
        result.observe("set-position-accepted", String(report.setPositionAccepted))
        result.observe("set-position-call-ms", ms(report.setPositionCallSeconds))
        result.observe("position-right-after-call", report.positionRightAfterCall.map(point) ?? "unreadable")
        result.observe("settled-after-ms", ms(report.settledAfter))
        result.observe("actual-frame-ax", report.actualFrameAX.map(rect) ?? "unreadable")
        result.observe("actual-frame-cg", report.actualFrameCG.map(rect) ?? "not listed")
        if let offset = report.offsetFromRequested {
            result.observe("actual-minus-requested", "(\(Int(offset.x.rounded())), \(Int(offset.y.rounded())))")
        }
        result.observe("size-changed-by-macos", String(report.sizeChanged))
        if let visible = report.visibleOnScreen {
            result.observe("visible-on-screen-px", "\(Int(visible.width.rounded())) x \(Int(visible.height.rounded()))")
        }
        result.observe("overlaps-other-screen", String(report.overlapsOtherScreen))
        result.observe("cg-on-screen-flag-while-parked", report.cgIsOnScreenWhileParked.map(String.init) ?? "not listed")
        result.observe("restore-accepted", String(report.restoreAccepted))
        result.observe("restore-call-ms", ms(report.restoreCallSeconds))
        result.observe("restored-after-ms", ms(report.restoredAfter))
        result.observe("restored-frame", report.restoredFrame.map(rect) ?? "unreadable")
        result.observe("restored-exactly", String(report.restoredExactly))
        result.observe("second-restore-needed", String(report.neededSecondRestore))
        if report.interrupted { result.observe("interrupted", "true") }
        for (i, note) in report.notes.enumerated() { result.observe("note-\(i + 1)", note) }

        let asRequested = (report.offsetFromRequested.map { abs($0.x) <= 1 && abs($0.y) <= 1 }) ?? false
        result.observe("parked-where-requested", String(asRequested))

        print("")
        print("Summary for \(appName) window \(window.id):")
        print("  requested top-left     \(point(report.requestedOrigin)); macOS left it at \(report.actualFrameAX.map(rect) ?? "?")")
        print("  parked where requested \(asRequested ? "yes" : "NO")")
        print("  settled after          \(ms(report.settledAfter)) ms (set call itself \(ms(report.setPositionCallSeconds)) ms)")
        print("  restored               \(report.restoredExactly ? "exactly" : "NOT exactly") after \(ms(report.restoredAfter)) ms")
        for note in report.notes { print("  note: \(note)") }

        let passed = !report.interrupted && report.setPositionAccepted && report.settledAfter != nil
            && asRequested && !report.overlapsOtherScreen && report.restoredExactly
        return finish(&result, passed: report.interrupted ? nil : passed)
    }

    // MARK: trackpad

    /// Frames from the framework's thread, handed to the main thread.
    private final class FrameBuffer {
        private let lock = NSLock()
        private var frames: [TouchFrame] = []

        func append(_ frame: TouchFrame) {
            lock.lock()
            frames.append(frame)
            lock.unlock()
        }

        func drain() -> [TouchFrame] {
            lock.lock()
            defer { lock.unlock() }
            let taken = frames
            frames = []
            return taken
        }
    }

    static func trackpad(_ args: [String]) -> Int32 {
        let parsed: Parsed
        do {
            parsed = try parse(args, values: ["--seconds"])
        } catch let error as UsageError {
            fputs("virtual trackpad: \(error.message)\n\n" + usage, stderr)
            return 2
        } catch {
            return 2
        }
        if parsed.help {
            print(usage, terminator: "")
            return 0
        }
        var seconds = 10.0
        if let text = parsed.values["--seconds"] {
            guard let n = Double(text), n >= 0.5, n <= 600 else {
                fputs("virtual trackpad: --seconds must be a number from 0.5 to 600\n", stderr)
                return 2
            }
            seconds = n
        }

        var result = LabResult(test: "virtual-trackpad")
        recordEnvironment(&result)
        result.observe("seconds", String(format: "%.1f", seconds))

        Interrupt.install()
        let buffer = FrameBuffer()
        let reader = TrackpadReader()
        reader.onFrame = { buffer.append($0) }
        let deviceCount: Int
        do {
            deviceCount = try reader.start()
        } catch {
            let message = error.localizedDescription
            fputs("virtual trackpad: \(message)\n", stderr)
            result.observe("error", message)
            return finish(&result, passed: false)
        }
        defer { reader.stop() }

        result.observe("devices-started", String(deviceCount))
        say("Reading \(deviceCount) multitouch device(s) for \(String(format: "%g", seconds)) s. "
            + "Put 1 to 4 fingers on the trackpad; swipe 3 fingers left and right.", into: &result)
        say("Note: macOS still performs its own 3-finger swipe (Desktops / Mission Control) at the same time; "
            + "this tool only reads and cannot stop it.", into: &result)

        var recognizers: [Int: SwipeRecognizer] = [:]
        var lastDown: [Int: Int] = [:]
        var histogram: [Int: Int] = [:]
        var maxFingers = 0
        var frameCount = 0
        var firstFrameAfter: TimeInterval?
        var swipes: [(device: Int, event: SwipeEvent)] = []
        let start = ProcessInfo.processInfo.systemUptime
        var lastTimestamp: [Int: Double] = [:]
        var timestampStepsBackwards = 0

        _ = waitUntil(timeout: seconds, interval: 0.01) {
            for frame in buffer.drain() {
                frameCount += 1
                if firstFrameAfter == nil { firstFrameAfter = ProcessInfo.processInfo.systemUptime - start }
                if let last = lastTimestamp[frame.device], frame.timestamp < last { timestampStepsBackwards += 1 }
                lastTimestamp[frame.device] = frame.timestamp

                let down = frame.downCount
                histogram[down, default: 0] += 1
                maxFingers = max(maxFingers, down)
                if lastDown[frame.device] != down {
                    let t = String(format: "%5.2f s", ProcessInfo.processInfo.systemUptime - start)
                    say("\(t)  device \(frame.device): \(down) finger(s) down", into: &result)
                    lastDown[frame.device] = down
                }
                var recognizer = recognizers[frame.device] ?? SwipeRecognizer()
                if let event = recognizer.feed(frame) {
                    swipes.append((frame.device, event))
                    let t = String(format: "%5.2f s", ProcessInfo.processInfo.systemUptime - start)
                    say(String(format: "%@  device %d: 3-finger swipe %@ (travel %.2f trackpad widths, drift %.2f, %.0f ms)",
                               t, frame.device, event.direction.rawValue.uppercased(), abs(event.travel), event.drift,
                               event.duration * 1000), into: &result)
                }
                recognizers[frame.device] = recognizer
            }
            return Interrupt.requested
        }
        reader.stop()
        // Frames that arrived while stopping are dropped on purpose.

        let left = swipes.filter { $0.event.direction == .left }.count
        let right = swipes.filter { $0.event.direction == .right }.count
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        result.observe("frames", String(frameCount))
        result.observe("frames-per-second", frameCount == 0 ? "0" : String(format: "%.0f", Double(frameCount) / elapsed))
        result.observe("first-frame-after-ms", ms(firstFrameAfter))
        result.observe("max-fingers-down", String(maxFingers))
        result.observe("frames-by-finger-count", histogram.keys.sorted().map { "\($0):\(histogram[$0] ?? 0)" }.joined(separator: " "))
        result.observe("swipes-left", String(left))
        result.observe("swipes-right", String(right))
        result.observe("timestamps-went-backwards", String(timestampStepsBackwards))
        result.observe("macos-own-swipe", "not suppressed: macOS sees the same touches (reader only)")
        if Interrupt.requested { result.observe("interrupted", "true") }

        print("")
        print("Summary: \(frameCount) frame(s), most fingers down \(maxFingers), 3-finger swipes: \(left) left, \(right) right.")
        if frameCount == 0 {
            print("No touches arrived. Touch the trackpad while the test runs; if you did, MultitouchSupport may need a permission or does not deliver frames to this process.")
        }

        // Verdict: at least one swipe was recognized. No touches at all = no verdict.
        let passed: Bool? = swipes.isEmpty ? nil : true
        return finish(&result, passed: passed)
    }
}
