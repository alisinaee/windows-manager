import AppKit
import Foundation

// Scrambling: change the real desktop with NSWorkspace and AppleScript so the restore has work to do.
// Moving a window to another Desktop cannot be scripted reliably, so S2 leaves that part to what the OS gives us
// and says so in the log.

extension DebugTestRunner {
    func scramble(_ s: DebugScenarioID, profile: Profile, sink: DebugSink) async {
        switch s {
        case .s1Cold:
            // TextEdit reopens the windows it had when it quit (state restoration); with none it shows an Open
            // panel (an untitled 280x168 window), so it is quit with two documents open, as on a normal day.
            _ = await osa("tell application \"TextEdit\" to activate")
            _ = await osa("tell application \"TextEdit\" to close every document saving no")
            for text in ["A", "B"] {
                _ = await osa("tell application \"TextEdit\" to make new document with properties {text:\"\(text)\"}")
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await quitFixtures(sink)
            await closeFinderWindows()
            sink.send(.log("cold: fixture apps quit; the number of Desktops cannot be reduced here, "
                + "so addDesktop is only expected when fewer than 3 exist"))
        case .s2WrongPlace, .s4Extras, .s7Rerun, .home:
            await openAll(profile, sink)
            await shiftAll(profile, sink)
            sink.send(.log("wrong place: frames shifted +200 and halved; Desktop placement left as is"))
            if s == .s4Extras { await addExtra(sink) }
        case .s3Mixed:
            await openAll(profile, sink)
            await shiftAll(profile, sink)
            await ax("TextEdit", "set value of attribute \"AXFullScreen\" of window 1 to true")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await ax("Notes", "set value of attribute \"AXMinimized\" of window 1 to true")
            await closeFinderWindows()
            _ = await osa("tell application \"System Events\" to set visible of process \"Calculator\" to false")
            sink.send(.log("mixed: TextEdit full screen, Notes minimized, Calculator hidden, Finder without window"))
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // MARK: Pieces

    private func quitFixtures(_ sink: DebugSink) async {
        for bundle in [Self.textEdit, Self.calculator, Self.notes, Self.safari] {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) { app.terminate() }
        }
        for _ in 0..<10 {
            if running([Self.textEdit, Self.calculator, Self.notes, Self.safari]).isEmpty { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        for app in running([Self.textEdit, Self.calculator, Self.notes, Self.safari]) {
            sink.send(.log("force quit \(app.localizedName ?? "?")"))
            app.forceTerminate()
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private func running(_ bundles: [String]) -> [NSRunningApplication] {
        bundles.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    private func launch(_ bundle: String) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    private func closeFinderWindows() async {
        _ = await osa("tell application \"Finder\" to close every window")
    }

    /// Every fixture app open with the right number of windows, the way a normal day looks.
    private func openAll(_ profile: Profile, _ sink: DebugSink) async {
        await quitFixtures(sink)
        await launch(Self.calculator)
        await launch(Self.notes)
        _ = await osa("tell application \"TextEdit\" to activate")
        _ = await osa("tell application \"TextEdit\" to close every document saving no")
        for text in ["A", "B"] {
            _ = await osa("tell application \"TextEdit\" to make new document with properties {text:\"\(text)\"}")
        }
        _ = await osa("tell application \"Safari\" to make new document with properties {URL:\"about:blank\"}")
        _ = await osa("tell application \"Finder\" to make new Finder window to (path to documents folder)")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    /// Wrong frames: +200 and half size, window by window in z-order.
    private func shiftAll(_ profile: Profile, _ sink: DebugSink) async {
        var counts: [String: Int] = [:]
        for w in profile.windows {
            let name = w.app.name
            let index = (counts[name] ?? 0) + 1
            counts[name] = index
            let f = w.frame
            await ax(name, "set position of window \(index) to {\(Int(f.minX) + 200), \(Int(f.minY) + 200)}")
            await ax(name, "set size of window \(index) to {\(Int(max(f.width / 2, 300))), \(Int(max(f.height / 2, 250)))}")
        }
    }

    private func addExtra(_ sink: DebugSink) async {
        let before = Set(await liveWindows().map(\.windowID))
        _ = await osa("tell application \"TextEdit\" to make new document with properties {text:\"C\"}")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await ax("TextEdit", "set position of window 1 to {1000, 700}")
        await ax("TextEdit", "set size of window 1 to {500, 300}")
        try? await Task.sleep(nanoseconds: 500_000_000)
        let new = await liveWindows().filter { !before.contains($0.windowID) && $0.bundleID == Self.textEdit }
        sink.markedExtras = Set(new.map(\.windowID))
        sink.send(.log("extra TextEdit C window ids: \(new.map(\.windowID))"))
    }

    // MARK: AppleScript

    private func ax(_ process: String, _ body: String) async {
        _ = await osa("tell application \"System Events\" to tell process \"\(process)\" to \(body)")
    }

    @discardableResult
    func osa(_ script: String) async -> String {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            do { try p.run() } catch { return "osascript failed: \(error)" }
            p.waitUntilExit()
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }.value
    }
}

// MARK: - Power-user primitives (P6.124)

/// Outcome of one power-user scramble primitive. `size` is set only by size readbacks.
struct ScrambleResult: Equatable, Sendable {
    var ok: Bool
    var note: String
    var size: CGSize?

    init(ok: Bool, note: String, size: CGSize? = nil) {
        self.ok = ok
        self.note = note
        self.size = size
    }
}

/// Pure helpers behind the primitives: frames, parsing, verdicts. No AX or NSWorkspace calls here.
enum ScrambleMath {
    /// Same tolerance as DebugVerify.framesMatch.
    static let tolerance: CGFloat = 4
    static let minHalfWidth: CGFloat = 300
    static let minHalfHeight: CGFloat = 250

    /// A frame at the given origin, which may be negative.
    static func offScreenFrame(origin: CGPoint, size: CGSize) -> CGRect {
        CGRect(origin: origin, size: size)
    }

    /// True when the frame does not touch any display (global top-left coordinates).
    static func isEntirelyOffScreen(_ frame: CGRect, displays: [CGRect]) -> Bool {
        !displays.contains { $0.intersects(frame) }
    }

    /// Half the size, never below the minimum the shifted-window scramble already uses.
    static func halfSize(of size: CGSize) -> CGSize {
        CGSize(width: max((size.width / 2).rounded(.down), minHalfWidth),
               height: max((size.height / 2).rounded(.down), minHalfHeight))
    }

    /// Whether the app kept the requested size; when false the readback is the limit it imposed.
    static func sizeAccepted(requested: CGSize, actual: CGSize) -> Bool {
        abs(requested.width - actual.width) <= tolerance && abs(requested.height - actual.height) <= tolerance
    }

    static func positionMatches(_ origin: CGPoint, _ actual: CGPoint) -> Bool {
        abs(origin.x - actual.x) <= tolerance && abs(origin.y - actual.y) <= tolerance
    }

    /// Parses AppleScript list output such as "960, 900" or "{960, 900}".
    static func parsePair(_ output: String) -> (Int, Int)? {
        let parts = output
            .trimmingCharacters(in: CharacterSet(charactersIn: "{} \r\n\t"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        return (a, b)
    }

    static func parseCount(_ output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func parseBool(_ output: String) -> Bool? {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// True when every value in an AppleScript list (for example "true, true") equals `expected`, and there is one.
    static func flagsMatch(_ output: String, expected: Bool) -> Bool {
        let tokens = output
            .trimmingCharacters(in: CharacterSet(charactersIn: "{} \r\n\t"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { $0 == (expected ? "true" : "false") }
    }

    /// osascript writes its errors into the same merged output as the result.
    static func scriptFailed(_ output: String) -> Bool {
        output.contains("execution error") || output.hasPrefix("osascript failed")
    }

    /// Escapes a value for use inside a double-quoted AppleScript string.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Trims, drops empties and duplicates, keeps the order.
    static func normalizedBundles(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in raw.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !item.isEmpty {
            if seen.insert(item).inserted { out.append(item) }
        }
        return out
    }

    static func shouldKeepWaiting(found: Bool, elapsed: TimeInterval, limit: TimeInterval) -> Bool {
        !found && elapsed < limit
    }

    static func firstWindowResult(app: String, found: Bool, elapsed: TimeInterval, limit: TimeInterval) -> ScrambleResult {
        if found {
            return ScrambleResult(ok: true, note: "\(app): first window after \(String(format: "%.1f", elapsed))s")
        }
        return ScrambleResult(ok: false, note: "\(app): no window within \(String(format: "%.0f", limit))s")
    }

    static func createdResult(created: Int, wanted: Int) -> ScrambleResult {
        ScrambleResult(ok: created == wanted, note: "created \(created) of \(wanted) windows")
    }

    static func focusResult(app: String, frontmost: String?, expected: String) -> ScrambleResult {
        let ok = frontmost == expected
        return ScrambleResult(ok: ok, note: ok ? "\(app) is frontmost" : "frontmost is \(frontmost ?? "none")")
    }

    static func preOpenResult(wanted: Int, missing: [String]) -> ScrambleResult {
        let opened = wanted - missing.count
        let tail = missing.isEmpty ? "" : "; not installed: \(missing.joined(separator: ", "))"
        return ScrambleResult(ok: missing.isEmpty && wanted > 0, note: "pre-opened \(opened) of \(wanted)\(tail)")
    }
}

extension DebugTestRunner {
    /// Moves window `index` of the app to `origin` (may be negative), then reads position and size back and checks
    /// the window now lies entirely off every display.
    func moveWindowOffScreen(_ bundle: String, index: Int = 1, to origin: CGPoint, sink: DebugSink) async -> ScrambleResult {
        let name = processName(bundle)
        let set = await processScript(name, "set position of window \(index) to {\(Int(origin.x)), \(Int(origin.y))}")
        let pos = await processScript(name, "get position of window \(index)")
        let dims = await processScript(name, "get size of window \(index)")
        var result: ScrambleResult
        if ScrambleMath.scriptFailed(set) || ScrambleMath.scriptFailed(pos) || ScrambleMath.scriptFailed(dims),
           let p = ScrambleMath.parsePair(pos), let s = ScrambleMath.parsePair(dims) {
            let got = CGPoint(x: p.0, y: p.1)
            let size = CGSize(width: s.0, height: s.1)
            let frame = ScrambleMath.offScreenFrame(origin: got, size: size)
            let offScreen = ScrambleMath.isEntirelyOffScreen(frame, displays: DisplayMap.current().map(\.frame))
            let placed = ScrambleMath.positionMatches(origin, got)
            let state = offScreen ? "off screen" : (placed ? "still on screen" : "clamped by the app or OS")
            result = ScrambleResult(ok: placed && offScreen,
                note: "\(name) window \(index) at \(p.0),\(p.1) \(s.0)x\(s.1) \(state)", size: size)
        } else {
            result = ScrambleResult(ok: false, note: "could not move \(name) window \(index): \(set)\(pos)")
        }
        sink.send(.log("offscreen: \(result.note)"))
        return result
    }

    /// Asks the app for `width` x `height` and reads back what it allowed. ok means the readback worked, not that
    /// the size was accepted: compare `size` with the request (ScrambleMath.sizeAccepted).
    func setImpossibleSize(_ bundle: String, index: Int = 1, width: Int, height: Int, sink: DebugSink) async -> ScrambleResult {
        let name = processName(bundle)
        let set = await processScript(name, "set size of window \(index) to {\(width), \(height)}")
        let dims = await processScript(name, "get size of window \(index)")
        var result: ScrambleResult
        if !ScrambleMath.scriptFailed(dims), let parsed = ScrambleMath.parsePair(dims) {
            let actual = CGSize(width: parsed.0, height: parsed.1)
            let requested = CGSize(width: width, height: height)
            let verdict = ScrambleMath.sizeAccepted(requested: requested, actual: actual) ? "accepted" : "limited"
            result = ScrambleResult(ok: true,
                note: "\(name) asked \(width)x\(height), allowed \(parsed.0)x\(parsed.1) (\(verdict))", size: actual)
        } else {
            result = ScrambleResult(ok: false, note: "could not read size of \(name) window \(index): \(set)\(dims)")
        }
        sink.send(.log("size: \(result.note)"))
        return result
    }

    /// Puts every window of the app at `origin`, each at half its current size (never below the minimum).
    func stackWindows(_ bundle: String, at origin: CGPoint, sink: DebugSink) async -> ScrambleResult {
        let name = processName(bundle)
        let count = ScrambleMath.parseCount(await processScript(name, "count of windows")) ?? 0
        guard count > 0 else {
            let result = ScrambleResult(ok: false, note: "\(name) has no windows to stack")
            sink.send(.log("stack: \(result.note)"))
            return result
        }
        var failures: [Int] = []
        for index in 1...count {
            let dims = ScrambleMath.parsePair(await processScript(name, "get size of window \(index)"))
            guard let dims else { failures.append(index); continue }
            let half = ScrambleMath.halfSize(of: CGSize(width: dims.0, height: dims.1))
            let moved = await processScript(name, "set position of window \(index) to {\(Int(origin.x)), \(Int(origin.y))}")
            let resized = await processScript(name, "set size of window \(index) to {\(Int(half.width)), \(Int(half.height))}")
            if ScrambleMath.scriptFailed(moved) || ScrambleMath.scriptFailed(resized) { failures.append(index) }
        }
        let result = ScrambleResult(ok: failures.isEmpty,
            note: "stacked \(count - failures.count) of \(count) \(name) windows at \(Int(origin.x)),\(Int(origin.y)) half size"
                + (failures.isEmpty ? "" : "; failed windows \(failures)"))
        sink.send(.log("stack: \(result.note)"))
        return result
    }

    /// Minimizes (or unminimizes) every window of the app and reads the flags back.
    func setWindowsMinimized(_ bundle: String, minimized: Bool, sink: DebugSink) async -> ScrambleResult {
        let name = processName(bundle)
        let value = minimized ? "true" : "false"
        let set = await processScript(name, "set value of attribute \"AXMinimized\" of every window to \(value)")
        let flags = await processScript(name, "get value of attribute \"AXMinimized\" of every window")
        let ok = !ScrambleMath.scriptFailed(set) && ScrambleMath.flagsMatch(flags, expected: minimized)
        let result = ScrambleResult(ok: ok, note: "\(name) windows minimized=\(value) readback \(flags.trimmingCharacters(in: .whitespacesAndNewlines))")
        sink.send(.log("minimize: \(result.note)"))
        return result
    }

    /// Hides or unhides the app (System Events "visible" flag) and reads it back.
    func setAppHidden(_ bundle: String, hidden: Bool, sink: DebugSink) async -> ScrambleResult {
        let name = processName(bundle)
        let set = await processScript(name, "set visible to \(hidden ? "false" : "true")")
        let visible = ScrambleMath.parseBool(await processScript(name, "get visible"))
        let ok = !ScrambleMath.scriptFailed(set) && visible == !hidden
        let visibleText = visible.map { "\($0)" } ?? "unknown"
        let result = ScrambleResult(ok: ok, note: "\(name) hidden=\(hidden) visible readback \(visibleText)")
        sink.send(.log("hide: \(result.note)"))
        return result
    }

    /// Quits any running copy, launches the app without activating it and waits up to `seconds` for its first window.
    func launchCold(_ bundle: String, waitUpTo seconds: TimeInterval, sink: DebugSink) async -> ScrambleResult {
        let name = processName(bundle)
        await quitAndWait(bundle)
        await launch(bundle)
        let start = Date()
        var elapsed: TimeInterval = 0
        var found = false
        while true {
            found = await liveWindows().contains { $0.bundleID == bundle }
            elapsed = Date().timeIntervalSince(start)
            guard ScrambleMath.shouldKeepWaiting(found: found, elapsed: elapsed, limit: seconds) else { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let result = ScrambleMath.firstWindowResult(app: name, found: found, elapsed: elapsed, limit: seconds)
        sink.send(.log("cold launch: \(result.note)"))
        return result
    }

    /// Closes every window of the app by pressing each close button, and keeps the app running.
    func closeAllWindows(_ bundle: String, sink: DebugSink) async -> ScrambleResult {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else {
            let result = ScrambleResult(ok: false, note: "\(bundle) is not running")
            sink.send(.log("close windows: \(result.note)"))
            return result
        }
        let name = processName(bundle)
        let script = """
        tell application "System Events"
            tell process "\(ScrambleMath.escaped(name))"
                repeat (count of windows) times
                    try
                        perform action "AXPress" of (first button of window 1 whose subrole is "AXCloseButton")
                    end try
                end repeat
            end tell
        end tell
        """
        _ = await osa(script)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let left = ScrambleMath.parseCount(await processScript(name, "count of windows"))
        let stillRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
        let ok = left == 0 && stillRunning
        let leftText = left.map { "\($0)" } ?? "unknown"
        let result = ScrambleResult(ok: ok, note: "\(name) windows left \(leftText), running \(stillRunning)")
        sink.send(.log("close windows: \(result.note)"))
        return result
    }

    /// Opens `count` new windows or documents through the app's own File > New item (AX), as AppLauncher does.
    func openWindows(_ bundle: String, count: Int, sink: DebugSink) async -> ScrambleResult {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier else {
            let result = ScrambleResult(ok: false, note: "\(bundle) is not running")
            sink.send(.log("new windows: \(result.note)"))
            return result
        }
        var created = 0
        for _ in 0..<max(count, 0) {
            let pressed = await Task.detached { AppLauncher.pressNewWindowMenuItem(pid: pid) }.value
            if pressed { created += 1 }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        let result = ScrambleMath.createdResult(created: created, wanted: count)
        sink.send(.log("new windows \(processName(bundle)): \(result.note)"))
        return result
    }

    /// Activates the app and reads back whether it is frontmost.
    func bringFrontAndFocus(_ bundle: String, sink: DebugSink) async -> ScrambleResult {
        let name = processName(bundle)
        _ = await osa("tell application id \"\(ScrambleMath.escaped(bundle))\" to activate")
        try? await Task.sleep(nanoseconds: 500_000_000)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let result = ScrambleMath.focusResult(app: name, frontmost: front, expected: bundle)
        sink.send(.log("focus: \(result.note)"))
        return result
    }

    /// Launches each bundle without activating it, so another profile's apps are ready before a restore.
    func preOpenApps(_ bundles: [String], sink: DebugSink) async -> ScrambleResult {
        let list = ScrambleMath.normalizedBundles(bundles)
        var missing: [String] = []
        for bundle in list {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) == nil {
                missing.append(bundle)
                continue
            }
            await launch(bundle)
        }
        let result = ScrambleMath.preOpenResult(wanted: list.count, missing: missing)
        sink.send(.log("pre-open: \(result.note)"))
        return result
    }

    // MARK: Wrappers

    /// The process name System Events uses: the running app's name, else the app bundle's name.
    private func processName(_ bundle: String) -> String {
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundle.split(separator: ".").last.map(String.init) ?? bundle
    }

    /// Runs one System Events statement against a process and returns the merged osascript output.
    private func processScript(_ name: String, _ body: String) async -> String {
        await osa("tell application \"System Events\" to tell process \"\(ScrambleMath.escaped(name))\" to \(body)")
    }

    /// Terminates every running copy, force-quits stragglers, and waits for them to go.
    private func quitAndWait(_ bundle: String) async {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) { app.terminate() }
        for _ in 0..<10 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) { app.forceTerminate() }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}

extension DebugTestRunner {
    /// Power-user scramble (P6.126): open the apps of the profile, then shift every window +200 and halve its size.
    func scramblePowerUser(profile: Profile, sink: DebugSink) async {
        var seen = Set<String>()
        for w in profile.windows {
            guard let bundle = w.app.bundleID, seen.insert(bundle).inserted else { continue }
            await launch(bundle)
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await shiftAll(profile, sink)
        sink.send(.log("shifted: apps opened, frames moved +200 and halved"))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
}
