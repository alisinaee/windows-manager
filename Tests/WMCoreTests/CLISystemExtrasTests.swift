import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// `wm hotkeys`, `wm backup`, `wm windows list`, `wm updates check`, `wm layouts zones`, run through a Registry
/// with injected stores. Nothing here touches real defaults, preferences, windows or the network.
@Suite struct CLISystemExtrasTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CLISystemExtras-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Hotkeys

    private func hotkeyRegistry() -> (Registry, UserDefaults, String) {
        let suite = "wm.test.hotkeys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let r = Registry()
        HotkeyCommands.register(r) { HotkeyStore(defaults: defaults) }
        return (r, defaults, suite)
    }

    @Test func hotkeyKeysParseAndFormat() throws {
        let c = try HotkeyKeys.parse("ctrl+opt+cmd+Left")
        #expect(c.keyCode == 123)
        #expect(c.modifiers == [.control, .option, .command])
        #expect(HotkeyKeys.text(carbonKeyCode: 123, carbonModifiers: ShortcutBridge.carbonModifiers(c.modifiers)) == "ctrl+opt+cmd+left")
        #expect(throws: ServiceError.self) { try HotkeyKeys.parse("left") }          // no modifier
        #expect(throws: ServiceError.self) { try HotkeyKeys.parse("ctrl+nope") }
        #expect(throws: ServiceError.self) { try HotkeyKeys.parse("ctrl+a+b") }
    }

    @Test func hotkeysSetListClearRoundTrip() throws {
        let (r, defaults, suite) = hotkeyRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let set = r.execute(["hotkeys", "set", "workspace.next", "ctrl+opt+cmd+right", "--json"])
        #expect(set.exit == .ok)
        #expect(defaults.string(forKey: "KeyboardShortcuts_workspace.next") == #"{"carbonKeyCode":124,"carbonModifiers":6400}"#)
        let list = r.execute(["hotkeys", "list"])
        #expect(list.output.contains("workspace.next\tctrl+opt+cmd+right\tNext workspace"))
        #expect(list.output.contains("workspace.previous\t-\t"))
        let json = r.execute(["hotkeys", "list", "--json"]).output
        #expect(json.contains(#""shortcut":"ctrl+opt+cmd+right""#))
        #expect(r.execute(["hotkeys", "clear", "workspace.next"]).exit == .ok)
        #expect(defaults.object(forKey: "KeyboardShortcuts_workspace.next") == nil)
    }

    @Test func hotkeysRejectBadInput() {
        let (r, defaults, suite) = hotkeyRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(r.execute(["hotkeys", "set", "nope.name", "ctrl+opt+1"]).exit == .notFound)
        #expect(r.execute(["hotkeys", "set", "workspace.next", "ctrl+nope"]).exit == .usage)
        #expect(r.execute(["hotkeys", "set", "workspace.next"]).exit == .usage)               // missing arg
        #expect(r.execute(["hotkeys", "set", "workspace.next", "cmd+q"]).exit == .runtime)    // system shortcut
        #expect(r.execute(["hotkeys", "set", "workspace.1", "ctrl+opt+1"]).exit == .ok)
        #expect(r.execute(["hotkeys", "set", "workspace.2", "ctrl+opt+1"]).exit == .runtime)  // already used
    }

    // MARK: Backup

    private final class Prefs { var domains: [String: [String: Any]]
        init(_ d: [String: [String: Any]]) { domains = d }
        func read(_ domain: String) -> [String: Any] { domains[domain] ?? [:] } }
    private final class Runner: CommandRunning {
        var calls: [[String]] = []
        func run(_ path: String, arguments: [String]) throws -> CommandResult {
            calls.append([path] + arguments); return CommandResult(status: 0)
        }
    }

    private func backupFixture() -> (Registry, Runner, URL) {
        let folder = tempDir()
        let prefs = Prefs([
            SpaceBindingsBackup.spacesDomain: [SpaceBindingsBackup.spacesRootKey: ["a": 1]],
            SpaceBindingsBackup.hotkeysDomain: [SpaceBindingsBackup.hotkeysRootKey: ["79": ["enabled": true]]],
        ])
        let runner = Runner()
        let r = Registry()
        BackupCommands.register(r) { SpaceBindingsBackup(folder: folder, reader: prefs.read, runner: runner) }
        return (r, runner, folder)
    }

    @Test func backupCreateAndList() {
        let (r, _, folder) = backupFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(r.execute(["backup", "list"]).output == "No backups.")
        let made = r.execute(["backup", "create", "--reason", "cli test", "--json"])
        #expect(made.exit == .ok)
        #expect(made.output.contains(folder.lastPathComponent))
        let list = r.execute(["backup", "list", "--json"])
        #expect(list.output.contains(#""reason":""#))
        #expect(list.output.contains(#""backups":["#))
    }

    @Test func backupRestoreNeedsYes() {
        let (r, runner, folder) = backupFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = r.execute(["backup", "create"])
        let refused = r.execute(["backup", "restore", "latest"])
        #expect(refused.exit == .usage)
        #expect(refused.output.contains("--yes"))
        #expect(runner.calls.isEmpty)
        #expect(r.execute(["backup", "restore", "missing-id", "--yes"]).exit == .notFound)
        let done = r.execute(["backup", "restore", "latest", "--yes", "--no-dock-restart"])
        #expect(done.exit == .ok)
        #expect(runner.calls.count == 2)                          // two `defaults import`, no killall
        #expect(!runner.calls.contains { $0.first == "/usr/bin/killall" })
    }

    // MARK: Windows

    @Test func windowListRowsFilterAndFormat() {
        let displays = [DisplaySpaces(displayIdentifier: "Main", displayName: "Built-in", currentSpaceID: 1, spaces: [
            SpaceInfo(id: 1, uuid: "a", kind: .desktop, index: 0, isCurrent: true),
            SpaceInfo(id: 2, uuid: "b", kind: .desktop, index: 1, isCurrent: false),
            SpaceInfo(id: 3, uuid: "c", kind: .fullscreen, index: 2, isCurrent: false),
        ])]
        let windows = [
            CatalogWindow(windowID: 10, pid: 1, appName: "Safari", title: "Home", bounds: CGRect(x: 0, y: 25, width: 800, height: 600), isOnScreen: true, spaceIDs: [1]),
            CatalogWindow(windowID: 11, pid: 2, appName: "Notes", title: nil, bounds: CGRect(x: 5, y: 5, width: 300, height: 200), spaceIDs: [2]),
            CatalogWindow(windowID: 12, pid: 3, appName: "Keynote", title: nil, bounds: .zero, spaceIDs: [3]),
            CatalogWindow(windowID: 13, pid: 4, appName: "Overlay", title: nil, bounds: .zero, spaceIDs: []),
        ]
        let all = WindowListing.rows(windows: windows, displays: displays)
        #expect(all.map(\.id) == [10, 11, 12])
        #expect(all[1].spaces == [WindowListSpace(id: 2, display: "Built-in", kind: "desktop", desktop: 2)])
        #expect(all[2].spaces.first?.kind == "fullscreen")
        #expect(WindowListing.rows(windows: windows, displays: displays, app: "SAF").map(\.id) == [10])
        #expect(WindowListing.rows(windows: windows, displays: displays, spaceID: 2).map(\.id) == [11])
        #expect(WindowListing.rows(windows: windows, displays: displays, onScreenOnly: true).map(\.id) == [10])
        #expect(WindowListing.rows(windows: windows, displays: displays, includeSpaceless: true).count == 4)
        #expect(WindowListing.line(all[0]) == "10\tSafari\tDesktop 1\t0,25 800x600\tHome")
    }

    @Test func windowsListCommandParsesOptions() {
        let r = Registry()
        let w = [CatalogWindow(windowID: 7, pid: 1, appName: "Safari", title: "T", bounds: CGRect(x: 1, y: 2, width: 3, height: 4), spaceIDs: [1])]
        WindowListCommands.register(r, windows: { w }, displays: { [] })
        let out = r.execute(["windows", "list", "--app", "saf", "--json"])
        #expect(out.exit == .ok)
        #expect(out.output.contains(#""id":7"#))
        #expect(r.execute(["windows", "list", "--space", "abc"]).exit == .usage)
        #expect(r.execute(["windows", "list", "--bogus"]).exit == .usage)
        #expect(r.execute(["windows", "list", "--app", "zzz"]).output == "No windows.")
    }

    // MARK: Updates

    private let appcast = """
    <?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
    <item><sparkle:version>9</sparkle:version><sparkle:shortVersionString>1.9</sparkle:shortVersionString><enclosure url="https://x/1.9.zip"/></item>
    <item><sparkle:version>10</sparkle:version><sparkle:shortVersionString>1.10</sparkle:shortVersionString><enclosure url="https://x/1.10.zip"/></item>
    </channel></rss>
    """

    @Test func appcastPicksNewestByBuild() {
        let items = UpdateCheck.parseAppcast(Data(appcast.utf8))
        #expect(items.count == 2)
        #expect(UpdateCheck.newest(items)?.shortVersion == "1.10")
        let info: [String: Any] = ["SUFeedURL": " https://x/appcast.xml ", "CFBundleVersion": "9", "CFBundleShortVersionString": "1.9"]
        let r = UpdateCheck.result(appPath: "/A.app", info: info, appcast: Data(appcast.utf8))
        #expect(r.updateAvailable == true)
        #expect(r.feedURL == "https://x/appcast.xml")
        #expect(r.downloadURL == "https://x/1.10.zip")
        let same = UpdateCheck.result(appPath: nil, info: ["SUFeedURL": "https://x", "CFBundleVersion": "10"], appcast: Data(appcast.utf8))
        #expect(same.updateAvailable == false)
        #expect(UpdateCheck.result(appPath: nil, info: ["SUFeedURL": "  "], appcast: nil).configured == false)
    }

    @Test func updatesCheckCommand() throws {
        let app = tempDir().appendingPathComponent("Fake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let plist = app.appendingPathComponent("Contents/Info.plist")
        func write(_ d: [String: Any]) { (d as NSDictionary).write(to: plist, atomically: true) }
        var fetched: [URL] = []
        let r = Registry()
        UpdateCommands.register(r, locate: { nil }, fetch: { fetched.append($0); return Data(self.appcast.utf8) })

        #expect(r.execute(["updates", "check"]).exit == .notFound)                       // no app, no --app
        write(["CFBundleVersion": "9"])
        let off = r.execute(["updates", "check", "--app", app.path])
        #expect(off.exit == .ok)
        #expect(off.output.contains("not configured"))
        #expect(fetched.isEmpty)                                                          // never contacts a server
        write(["SUFeedURL": "https://x/appcast.xml", "CFBundleVersion": "9", "CFBundleShortVersionString": "1.9"])
        let on = r.execute(["updates", "check", "--app", app.path, "--json"])
        #expect(on.output.contains(#""updateAvailable":true"#))
        #expect(fetched.count == 1)
        write(["SUFeedURL": "ftp://x/appcast.xml"])
        #expect(r.execute(["updates", "check", "--app", app.path]).exit == .runtime)
    }

    // MARK: Layout zones

    @Test func zoneRectParsing() throws {
        #expect(try LayoutZoneCommands.parseRect("0, 0,0.5,1") == NormalizedRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(throws: CLIFailure.self) { try LayoutZoneCommands.parseRect("0,0,1") }
        #expect(throws: CLIFailure.self) { try LayoutZoneCommands.parseRect("a,b,c,d") }
        #expect(throws: CLIFailure.self) { try LayoutZoneCommands.parseRect("0,0,nan,1") }
    }

    @Test func zoneCommandsEditAnInjectedStore() {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = LayoutService(store: LayoutStore(folder: folder))
        _ = try? service.create(name: "Work")
        let r = Registry()
        LayoutZoneCommands.register(r) { service }

        #expect(r.execute(["layouts", "zones", "add", "Work", "Left"]).exit == .usage)                 // --rect required
        #expect(r.execute(["layouts", "zones", "add", "Work", "Left", "--rect", "0,0,0.5,1"]).exit == .ok)
        #expect(r.execute(["layouts", "zones", "add", "Work", "Big", "--rect", "0,0,2,1"]).exit == .usage)   // outside display
        #expect(r.execute(["layouts", "zones", "set", "Work", "Left"]).exit == .usage)                 // nothing to change
        #expect(r.execute(["layouts", "zones", "set", "Work", "Left", "--rect", "0,0,0.25,1", "--name", "Narrow"]).exit == .ok)
        let list = r.execute(["layouts", "zones", "list", "Work", "--json"])
        #expect(list.output.contains(#""name":"Narrow""#))
        #expect(list.output.contains(#""width":0.25"#))
        #expect(r.execute(["layouts", "zones", "set", "Work", "Missing", "--name", "x"]).exit == .notFound)
        #expect(r.execute(["layouts", "zones", "remove", "Work", "Narrow"]).exit == .ok)
        #expect(r.execute(["layouts", "zones", "list", "Nope"]).exit == .notFound)
    }
}
