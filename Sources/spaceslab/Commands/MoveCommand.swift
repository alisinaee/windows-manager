import AppKit
import Foundation
import WMCore

enum MoveCommand {
    static let name = "move"
    static let help = "Move a window to another Desktop and check it (--probe, --window, --app, --self-test)"

    static let usage = """
        Usage: spaceslab move --probe
               spaceslab move --window <id> (--to <N> | --space-id <id>) [--method <name>] [--keep]
               spaceslab move --app <name>  (--to <N> | --space-id <id>) [--method <name>] [--keep]
               spaceslab move --self-test   (--to <N> | --space-id <id>) [--method <name>] [--keep]

          --probe        Read-only. Print which move methods this Mac offers and why, plus the SkyLight
                         classes, methods and symbols behind them. Moves nothing.
          --window <id>  Move one window (ids: spaceslab spaces --windows).
          --app <name>   Move every normal window of the app (name or bundle id) that sits on one Desktop.
          --self-test    Open a small window "Spaces Lab test window", move it, check, move it back, close it.
                         The safest way to try a method: it never touches another app.
          --to <N>       Target is Desktop N (1-based, full-screen Spaces not counted) of the display the
                         window is on.
          --space-id <id>  Target is this Space id instead. It must be a Desktop.
          --method <name>  Try only this method: \(MoveMethod.allCases.map(\.rawValue).joined(separator: ", ")).
                         Without it all available methods are tried in that order until one is verified.
          --keep         Do not move the window back afterwards (with --self-test the window is still closed).

        A move counts only when SkyLight reports the window on the target Space within 1 s (or after 3 s,
        marked "late"). Windows in full-screen Spaces, on several Spaces, or targets that are not a Desktop
        are refused. Every run is saved as a "move-<method>" lab result in ./lab-results ("move-probe" for --probe).

        """

    struct UsageError: Error {
        var message: String
    }

    struct Options {
        var probe = false
        var selfTest = false
        var window: UInt32?
        var app: String?
        var desktop: Int?
        var spaceID: UInt64?
        var method: MoveMethod?
        var keep = false

        var target: MoveTargetRequest? {
            if let desktop { return .desktopNumber(desktop) }
            if let spaceID { return .spaceID(spaceID) }
            return nil
        }

        var mode: String {
            if probe { return "probe" }
            if selfTest { return "self-test" }
            if window != nil { return "window" }
            return "app"
        }
    }

    // MARK: Entry

    static func run(_ args: [String]) -> Int32 {
        if args.contains("-h") || args.contains("--help") {
            print(usage, terminator: "")
            return 0
        }
        let options: Options
        do {
            options = try parse(args)
        } catch let error as UsageError {
            fputs("move: \(error.message)\n\n" + usage, stderr)
            return 2
        } catch {
            fputs("move: \(error.localizedDescription)\n", stderr)
            return 2
        }
        return options.probe ? probe() : perform(options)
    }

    static func parse(_ args: [String]) throws -> Options {
        var options = Options()
        var index = 0

        func value(for flag: String) throws -> String {
            index += 1
            guard index < args.count else { throw UsageError(message: "\(flag) needs a value") }
            return args[index]
        }

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--probe": options.probe = true
            case "--self-test": options.selfTest = true
            case "--keep": options.keep = true
            case "--window":
                guard let id = UInt32(try value(for: arg)), id > 0 else {
                    throw UsageError(message: "--window needs a window id (a positive number)")
                }
                options.window = id
            case "--app":
                let name = try value(for: arg)
                guard !name.isEmpty else { throw UsageError(message: "--app needs an app name") }
                options.app = name
            case "--to":
                guard let number = Int(try value(for: arg)), number >= 1 else {
                    throw UsageError(message: "--to needs a Desktop number, 1 or higher")
                }
                options.desktop = number
            case "--space-id":
                guard let id = UInt64(try value(for: arg)), id > 0 else {
                    throw UsageError(message: "--space-id needs a Space id (see spaceslab spaces)")
                }
                options.spaceID = id
            case "--method":
                let name = try value(for: arg)
                guard let method = MoveMethod(rawValue: name) else {
                    throw UsageError(message: "unknown method \(name); use one of "
                        + MoveMethod.allCases.map(\.rawValue).joined(separator: ", "))
                }
                options.method = method
            default:
                throw UsageError(message: "unknown option \(arg)")
            }
            index += 1
        }

        let modes = [options.probe, options.selfTest, options.window != nil, options.app != nil].filter { $0 }.count
        guard modes == 1 else {
            throw UsageError(message: "choose exactly one of --probe, --window, --app, --self-test")
        }
        if options.probe {
            guard options.desktop == nil, options.spaceID == nil, options.method == nil, !options.keep else {
                throw UsageError(message: "--probe takes no other options")
            }
        } else {
            guard (options.desktop == nil) != (options.spaceID == nil) else {
                throw UsageError(message: "give the target as either --to <N> or --space-id <id>")
            }
        }
        return options
    }

    // MARK: Output helpers

    private static let compactEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func json<T: Encodable>(_ value: T) -> String {
        (try? compactEncoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// "123: 1; 456: 5,6" for a window id (as text) -> Space ids map.
    private static func spacesText(_ spaces: [String: [UInt64]]) -> String {
        spaces.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.map(String.init).joined(separator: ","))" }.joined(separator: "; ")
    }

    /// "Desktop 2 (space 5, display 1)" or "Full screen: Safari (window 9) (space 37, display 1)".
    private static func place(_ spaceID: UInt64, in displays: [DisplaySpaces]) -> String {
        for (n, display) in displays.enumerated() {
            if let space = display.spaces.first(where: { $0.id == spaceID }) {
                return "\(SpacesCommand.label(space, in: display)) (space \(spaceID), display \(n + 1))"
            }
        }
        return "space \(spaceID)"
    }

    /// Saves the result, prints where, and returns the exit code (0 pass, 1 fail or undecided).
    private static func save(_ result: inout LabResult, passed: Bool?) -> Int32 {
        result.finish(passed: passed)
        do {
            let url = try result.save()
            print("\nSaved \(url.path)")
        } catch {
            fputs("move: could not save the lab result: \(error.localizedDescription)\n", stderr)
        }
        return passed == true ? 0 : 1
    }

    // MARK: --probe

    private static func probe() -> Int32 {
        var result = LabResult(test: "move-probe")
        result.observe("mode", "probe")
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Read-only probe: nothing is moved.\n")

        // Touching PrivateSymbols loads SkyLight, which also registers its Objective-C classes.
        guard PrivateSymbols.isLoaded else {
            let reason = PrivateSymbols.loadError ?? "unknown error"
            print("SkyLight could not be loaded: \(reason)")
            result.observe("skylight", "not loaded: \(reason)")
            return save(&result, passed: nil)
        }

        // 1. Methods
        print("Move methods (tried in this order):")
        let availability = SpaceMover.availability()
        for method in MoveMethod.allCases {
            let entry = availability[method] ?? MoveMethodAvailability(available: false, reason: "unknown")
            print("  \(pad(method.rawValue, 15)) \(entry.available ? "available    " : "NOT available")  \(entry.reason)")
            result.observe("method-\(method.rawValue)", (entry.available ? "available: " : "not available: ") + entry.reason)
        }
        let construction = SpaceMover.describeOperationConstruction()
        print("\nOperation object: \(construction)")
        result.observe("operation-object", construction)
        // SkyLight's fallback bridge hands the operation to WMClientWindowManager (WindowManagement.framework,
        // which AppKit loads). Without that class the bridged move would silently do nothing.
        let wmManager = NSClassFromString("WMClientWindowManager") != nil
        print("WMClientWindowManager (WindowManagement, loaded with AppKit): \(wmManager ? "present" : "MISSING")")
        result.observe("wm-client-window-manager", wmManager ? "present" : "missing")

        // 2. Image
        print("")
        if let image = SkyLightImage.info() {
            let header = "0x" + String(image.headerAddress, radix: 16)
            let slide = (image.slide < 0 ? "-" : "") + "0x" + String(abs(image.slide), radix: 16)
            print("SkyLight image: \(image.path)")
            print("  header \(header), slide \(slide), \(image.symbolTableEntries) symbol table entries")
            result.observe("image", "\(image.path) header \(header) slide \(slide) entries \(image.symbolTableEntries)")
        } else {
            let problem = SkyLightImage.problem ?? "unknown problem"
            print("SkyLight image symbol table: unavailable (\(problem))")
            result.observe("image", "symbol table unavailable: \(problem)")
        }

        // 3. Symbols
        let fragments = ["PerformAsynchronousBridged", "PerformSynchronousBridged", "WMBridgeDelegate",
                         "WindowManagementBridge", "MoveWindowsToManagedSpace"]
        // Hide Objective-C metadata and message-send stubs; they only repeat the class and method names.
        let symbols = SkyLightImage.symbols(containing: fragments).filter {
            !$0.name.hasPrefix("_OBJC_") && !$0.name.hasPrefix("__OBJC") && !$0.name.hasPrefix("_objc_msgSend$")
        }
        let exactExported = SkyLightImage.symbol(named: "_" + SpaceMoverNames.exportedPerform)
        print("\nSymbols matching \(fragments.joined(separator: " | ")) (\(symbols.count) found, "
            + "Objective-C metadata hidden):")
        let shown = symbols.prefix(70)
        for symbol in shown {
            print("  0x\(String(symbol.address, radix: 16))  \(symbol.isExported ? "exported " : "local    ")  \(symbol.name)")
        }
        if symbols.count > shown.count { print("  ... and \(symbols.count - shown.count) more") }
        print("  exported symbol _\(SpaceMoverNames.exportedPerform): "
            + (exactExported == nil ? "not in the symbol table (not exported)" : "present"))
        let internalFunction = symbols.first { !$0.isObjCMethod && $0.name.contains(SpaceMoverNames.exportedPerform) }
        result.observe("symbols-found", String(symbols.count))
        result.observe("perform-function", internalFunction.map {
            "\($0.name) address 0x\(String($0.address, radix: 16)) unslid 0x\(String($0.unslidAddress, radix: 16)) "
                + ($0.isExported ? "exported" : "local")
        } ?? "none found")
        result.observe("symbols", symbols.prefix(70).map {
            "\($0.name)@0x\(String($0.address, radix: 16))" + ($0.isExported ? "" : " (local)")
        }.joined(separator: "\n"))

        // 4. Classes
        let classNames = SkyLightImage.objcClassNames(containing: ["Bridged", "WindowManagementOperation"])
        let keyClasses = ["SLSBridgedMoveWindowsToManagedSpaceOperation",
                          "SLSAsynchronousBridgedWindowManagementOperation",
                          "SLSWindowManagementFallbackBridge"]
        print("\nObjC classes in SkyLight: \(SkyLightImage.objcClassNames().count) total, "
            + "\(classNames.count) with \"Bridged\" or \"WindowManagementOperation\" in the name")
        result.observe("classes-total", String(SkyLightImage.objcClassNames().count))
        result.observe("classes-matching", classNames.joined(separator: ", "))
        for line in wrap(classNames.filter { !keyClasses.contains($0) }, indent: "  ", width: 110) { print(line) }

        for name in keyClasses {
            let chain = SkyLightImage.objcClassChain(named: name)
            print("\n\(name):" + (chain.isEmpty ? " class not found" : ""))
            var summary: [String] = []
            for info in chain {
                print("  class \(info.name)" + (info.superclass.map { " : \($0)" } ?? ""))
                for ivar in info.instanceVariables { print("      ivar \(ivar)") }
                for method in info.methods.sorted(by: { ($0.isClassMethod ? 1 : 0, $0.name) < ($1.isClassMethod ? 1 : 0, $1.name) }) {
                    print("      \(method.signature)  [\(method.typeEncoding)]  imp 0x\(String(method.implementation, radix: 16))")
                    summary.append("\(info.name) \(method.signature) imp 0x\(String(method.implementation, radix: 16))")
                }
            }
            result.observe("methods-\(name)", chain.isEmpty ? "class not found" : summary.joined(separator: "\n"))
        }

        print("\nHow the bridged move works: build the operation object, then perform it. "
            + "The internal SLSPerformAsynchronousBridgedWindowManagementOperation and the operation's own "
            + "-performWithWMBridgeDelegate make the same call.")
        _ = save(&result, passed: nil)
        return 0
    }

    /// Joins names with ", " into lines of at most `width` characters.
    private static func wrap(_ names: [String], indent: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = indent
        for (n, name) in names.enumerated() {
            let piece = name + (n == names.count - 1 ? "" : ", ")
            if line.count + piece.count > width, line != indent {
                lines.append(trimmed(line))
                line = indent
            }
            line += piece
        }
        if line != indent { lines.append(trimmed(line)) }
        return lines
    }

    private static func trimmed(_ line: String) -> String {
        line.replacingOccurrences(of: " +$", with: "", options: .regularExpression)
    }

    // MARK: Real moves

    private struct Job {
        var windowID: UInt32
        var label: String
        var plan: MovePlan
    }

    private static func perform(_ options: Options) -> Int32 {
        var result = LabResult(test: "move-\(options.method?.rawValue ?? "auto")")
        result.observe("mode", options.mode)
        result.observe("method-requested", options.method?.rawValue ?? "all, in order")
        result.observe("keep", String(options.keep))
        if let desktop = options.desktop { result.observe("target-request", "Desktop \(desktop)") }
        if let spaceID = options.spaceID { result.observe("target-request", "space \(spaceID)") }
        for (method, text) in SpaceMover.availableMethods() { result.observe("available-\(method.rawValue)", text) }

        func refuse(_ message: String) -> Int32 {
            print("move: \(message)")
            result.observe("refused", message)
            result.step("refused: \(message)")
            return save(&result, passed: nil)
        }

        guard let request = options.target else { return refuse("no target given") }

        if options.selfTest { return selfTest(options, request: request, result: &result) }

        let displays: [DisplaySpaces]
        do { displays = try SpaceReader.displays() } catch { return refuse(error.localizedDescription) }
        let catalog = WindowCatalog.all()

        var jobs: [Job] = []
        var skipped: [String] = []
        if let id = options.window {
            guard let window = catalog.first(where: { $0.windowID == id }) else {
                return refuse("no normal window with id \(id) (list them with: spaceslab spaces --windows)")
            }
            do {
                let plan = try SpaceMover.plan(windowSpaceIDs: window.spaceIDs, target: request, displays: displays)
                jobs.append(Job(windowID: id, label: describe(window), plan: plan))
            } catch {
                return refuse(error.localizedDescription)
            }
        } else if let name = options.app {
            let apps = AXWindows.runningApps(matching: name)
            guard !apps.isEmpty else { return refuse("no running app matches \"\(name)\"") }
            let pids = Set(apps.map(\.processIdentifier))
            let windows = catalog.filter { pids.contains($0.pid) && $0.looksLikeUserWindow }.sorted { $0.windowID < $1.windowID }
            guard !windows.isEmpty else { return refuse("\"\(name)\" has no normal windows on a Space") }
            for window in windows {
                do {
                    let plan = try SpaceMover.plan(windowSpaceIDs: window.spaceIDs, target: request, displays: displays)
                    jobs.append(Job(windowID: window.windowID, label: describe(window), plan: plan))
                } catch {
                    skipped.append("window \(window.windowID) (\(describe(window))): \(error.localizedDescription)")
                }
            }
        }

        for note in skipped {
            print("Skipped \(note)")
            result.step("skipped \(note)")
        }
        result.observe("skipped", skipped.joined(separator: "\n"))
        let movable = jobs.filter { !$0.plan.isNoOp }
        for job in jobs where job.plan.isNoOp {
            print("Window \(job.windowID) (\(job.label)) is already on Desktop \(job.plan.targetDesktopNumber); nothing to do.")
        }
        guard !movable.isEmpty else { return refuse("no window to move") }

        var allPassed = true
        for job in movable {
            allPassed = runJob(job, options: options, displays: displays, result: &result) && allPassed
        }
        return save(&result, passed: allPassed)
    }

    private static func describe(_ window: CatalogWindow) -> String {
        let title = window.title.map { " \"\($0.count > 40 ? String($0.prefix(39)) + "…" : $0)\"" } ?? ""
        return "\(window.appName)\(title)"
    }

    /// Forward move, read-back, then move back to the original Space (unless --keep). True when everything
    /// that was asked for was verified.
    private static func runJob(_ job: Job, options: Options, displays: [DisplaySpaces], result: inout LabResult) -> Bool {
        let key = "window-\(job.windowID)"
        let plan = job.plan
        result.observe("\(key)-label", job.label)
        result.observe("\(key)-from", place(plan.sourceSpaceID, in: displays))
        result.observe("\(key)-to", place(plan.targetSpaceID, in: displays))
        print("\nWindow \(job.windowID): \(job.label)")
        print("  \(place(plan.sourceSpaceID, in: displays))  ->  \(place(plan.targetSpaceID, in: displays))")
        if plan.isCrossDisplay { print("  (the target Desktop is on another display)") }
        result.step("moving window \(job.windowID) from space \(plan.sourceSpaceID) to \(plan.targetSpaceID)")

        let forward = SpaceMover.move(windowIDs: [job.windowID], toSpace: plan.targetSpaceID, method: options.method)
        report(forward, title: "move", prefix: "\(key)-forward", result: &result)
        var passed = forward.success

        if options.keep {
            print("  --keep: the window stays on the target Space.")
            result.step("kept window \(job.windowID) on the target Space")
        } else {
            let now = SpaceReader.spaces(forWindows: [job.windowID])[job.windowID] ?? []
            if now == [plan.sourceSpaceID] {
                print("  Window is on its original Space; nothing to move back.")
                result.observe("\(key)-restore", "not needed, window is on its original Space")
            } else {
                let back = SpaceMover.move(windowIDs: [job.windowID], toSpace: plan.sourceSpaceID,
                                           method: forward.succeededWith ?? options.method)
                report(back, title: "move back", prefix: "\(key)-restore", result: &result)
                if !back.success {
                    passed = false
                    print("  WARNING: the window could not be moved back. Move it to "
                        + "\(place(plan.sourceSpaceID, in: displays)) by hand in Mission Control.")
                }
            }
        }
        result.observe("\(key)-passed", String(passed))
        return passed
    }

    /// Prints one outcome and records it as observations under `prefix`.
    private static func report(_ outcome: MoveOutcome, title: String, prefix: String, result: inout LabResult) {
        result.observe("\(prefix)-spaces-before", spacesText(outcome.spacesBefore))
        result.observe("\(prefix)-appkit-ready", String(outcome.appKitReady))
        result.observe("\(prefix)-elapsed", String(format: "%.2fs", outcome.elapsed))
        result.observe("\(prefix)-succeeded-with", outcome.succeededWith?.rawValue ?? (outcome.alreadyOnTarget ? "already on target" : "none"))
        result.observe("\(prefix)-final-spaces", spacesText(outcome.verifiedSpaces))
        result.observe("\(prefix)-json", json(outcome))

        if outcome.alreadyOnTarget {
            print("  \(title): window was already on the target Space.")
        } else if let method = outcome.succeededWith {
            let attempt = outcome.attempts.first { $0.method == method }
            let seconds = attempt?.secondsToVerify.map { String(format: " in %.2f s", $0) } ?? ""
            let late = attempt?.late == true ? " (late)" : ""
            print("  \(title): VERIFIED with \(method.rawValue)\(seconds)\(late)")
        } else {
            print("  \(title): NOT verified by any method. Final Spaces: \(spacesText(outcome.verifiedSpaces))")
        }
        if !outcome.appKitReady { print("  note: AppKit could not be initialised (not on the main thread?); WindowServer may ignore the move") }

        for attempt in outcome.attempts {
            let state: String
            if !attempt.invoked {
                state = "skipped"
            } else if attempt.verified {
                state = attempt.late ? "verified (late)" : "verified"
            } else {
                state = "NOT verified"
            }
            print("    \(pad(attempt.method.rawValue, 15)) \(pad(state, 16)) \(attempt.detail)")
            result.observe("\(prefix)-attempt-\(attempt.method.rawValue)", "\(state): \(attempt.detail)"
                + (attempt.spacesAfter.isEmpty ? "" : " | spaces after: \(spacesText(attempt.spacesAfter))"))
        }
    }

    // MARK: --self-test

    private static func selfTest(_ options: Options, request: MoveTargetRequest, result: inout LabResult) -> Int32 {
        print("Opening the test window \"Spaces Lab test window\" ...")
        let window = makeTestWindow()
        let number = MainActor.assumeIsolated { window.windowNumber }
        guard number > 0 else {
            closeTestWindow(window)
            print("move: the test window got no window number")
            result.observe("refused", "test window got no window number")
            return save(&result, passed: false)
        }
        let windowID = UInt32(number)
        result.step("opened test window \(windowID)")

        // The window has to show up on a Space before it can be moved.
        let appeared = waitUntil(timeout: 3.0) { (SpaceReader.spaces(forWindows: [windowID])[windowID] ?? []).count == 1 }
        guard appeared != nil else {
            closeTestWindow(window)
            print("move: the test window did not appear on a Space within 3 s")
            result.observe("refused", "test window did not appear on a Space")
            return save(&result, passed: false)
        }

        let displays: [DisplaySpaces]
        let plan: MovePlan
        do {
            displays = try SpaceReader.displays()
            plan = try SpaceMover.plan(windowSpaceIDs: SpaceReader.spaces(forWindows: [windowID])[windowID] ?? [],
                                       target: request, displays: displays)
        } catch {
            closeTestWindow(window)
            print("move: \(error.localizedDescription)")
            result.observe("refused", error.localizedDescription)
            return save(&result, passed: nil)
        }
        if plan.isNoOp {
            closeTestWindow(window)
            let message = "the test window opened on Desktop \(plan.targetDesktopNumber), which is the target; "
                + "choose a different --to"
            print("move: \(message)")
            result.observe("refused", message)
            return save(&result, passed: nil)
        }

        let job = Job(windowID: windowID, label: "Spaces Lab test window (own window)", plan: plan)
        let passed = runJob(job, options: options, displays: displays, result: &result)

        closeTestWindow(window)
        result.step("closed the test window")
        print("\nTest window closed.")
        return save(&result, passed: passed)
    }

    private static func makeTestWindow() -> NSWindow {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.finishLaunching()
            let window = NSWindow(contentRect: NSRect(x: 240, y: 360, width: 380, height: 110),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Spaces Lab test window"
            window.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "spaceslab move --self-test\nThis window is moved to another Desktop and back.")
            label.frame = NSRect(x: 16, y: 30, width: 348, height: 40)
            window.contentView?.addSubview(label)
            // Show it without taking keyboard focus from the terminal.
            window.orderFrontRegardless()
            return window
        }
    }

    private static func closeTestWindow(_ window: NSWindow) {
        MainActor.assumeIsolated {
            window.orderOut(nil)
            window.close()
        }
        // Let AppKit finish tearing the window down.
        _ = waitUntil(timeout: 0.2) { false }
    }
}

/// Names the probe prints; the same strings SpaceMover uses.
private enum SpaceMoverNames {
    static let exportedPerform = "SLSPerformAsynchronousBridgedWindowManagementOperation"
}
