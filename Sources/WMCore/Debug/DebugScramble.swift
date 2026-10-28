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
