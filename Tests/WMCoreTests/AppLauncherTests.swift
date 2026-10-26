import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import WMCore

// No test here opens, activates or quits a real app, and none moves a window. The folders searched are
// temporary directories or a fake file manager; "running apps" are injected.

// MARK: - Helpers

/// A temporary folder removed at the end of the test.
private final class TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func folder(_ name: String) throws -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Creates `<directory>/<name>.app`, with an Info.plist when a bundle id is given.
    @discardableResult
    func makeApp(_ name: String, in directory: URL, bundleID: String? = nil) throws -> URL {
        let app = directory.appendingPathComponent(name + ".app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if let bundleID {
            let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        return app
    }
}

/// A file manager with a made-up file tree, to show that the injected one is the one used.
private final class FakeFileManager: FileManager, @unchecked Sendable {
    var directories: Set<String> = []
    var listings: [String: [String]] = [:]

    override init() { super.init() }

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        guard directories.contains(path) else { return false }
        isDirectory?.pointee = true
        return true
    }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        guard let entries = listings[path] else { throw CocoaError(.fileReadNoSuchFile) }
        return entries
    }
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 800, _ h: CGFloat = 600) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

private func sample(_ time: TimeInterval, _ frames: CGRect...) -> AppLauncher.FrameSample {
    AppLauncher.FrameSample(time: time, frames: frames)
}

private func makeLauncher(searching directories: [URL], lookup: [String: URL] = [:],
                      fileManager: FileManager = .default) -> AppLauncher {
    AppLauncher(fileManager: fileManager, searchDirectories: directories,
                bundleLookup: { lookup[$0] }, runningApplications: { [] })
}

// MARK: - Options and result

@Suite struct LaunchOptionsTests {
    @Test func defaults() {
        let options = LaunchOptions()
        #expect(options.minWindows == 1)
        #expect(options.timeout == 20)
        #expect(options.reopenAfter == 3)
        #expect(options.settleTime == 0.8)
        #expect(options.maxSettleTime == 5)
        #expect(options.activates == false)
        #expect(options.activateToReopen == true)
    }

    @Test func staticDefaultsMatchTheInitializer() {
        #expect(LaunchOptions() == LaunchOptions(
            minWindows: LaunchOptions.defaultMinWindows, timeout: LaunchOptions.defaultTimeout,
            reopenAfter: LaunchOptions.defaultReopenAfter, settleTime: LaunchOptions.defaultSettleTime,
            maxSettleTime: LaunchOptions.defaultMaxSettleTime))
    }

    @Test func valuesCanBeChanged() {
        let options = LaunchOptions(minWindows: 3, timeout: 5, reopenAfter: 1, settleTime: 0.2, activates: true)
        #expect(options.minWindows == 3)
        #expect(options.timeout == 5)
        #expect(options.reopenAfter == 1)
        #expect(options.settleTime == 0.2)
        #expect(options.activates)
        #expect(options.maxSettleTime == 5)
    }

    @Test func optionsSurviveJSON() throws {
        let options = LaunchOptions(minWindows: 2, timeout: 9, activates: true, activateToReopen: false)
        let data = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(LaunchOptions.self, from: data) == options)
    }
}

@Suite struct LaunchResultTests {
    private let app = AppRef(bundleID: "com.example.app", name: "Example")

    @Test func isRunningFollowsTheStatus() {
        #expect(LaunchResult(app: app, status: .alreadyRunning).isRunning)
        #expect(LaunchResult(app: app, status: .launched).isRunning)
        #expect(!LaunchResult(app: app, status: .notFound).isRunning)
        #expect(!LaunchResult(app: app, status: .failed("boom")).isRunning)
        #expect(!LaunchResult(app: app, status: .timedOut).isRunning)
    }

    @Test func settledMeansTheSettledTimingIsSet() {
        var result = LaunchResult(app: app, status: .launched)
        #expect(!result.didSettle)
        result.timings.settled = 2.5
        #expect(result.didSettle)
    }

    @Test func failureReasonIsPartOfTheStatus() {
        #expect(LaunchResult.Status.failed("a") == .failed("a"))
        #expect(LaunchResult.Status.failed("a") != .failed("b"))
    }

    @Test func resultSurvivesJSON() throws {
        let result = LaunchResult(
            app: app, status: .failed("no luck"), pid: 123, windowCount: 2, systemWindowCount: 3, reopenCount: 1,
            activatedToReopen: true,
            timings: .init(launchCall: 0.2, axReady: 1, firstWindow: 1.5, settled: 2.3, total: 2.4))
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(LaunchResult.self, from: data) == result)
    }
}

// MARK: - isSettled

@Suite struct AppLauncherSettleTests {
    private let a = rect(100, 100)
    private let b = rect(200, 150, 900, 700)

    @Test func emptyHistoryIsNeverSettled() {
        #expect(!AppLauncher.isSettled(frames: [], now: 100, settleTime: 0.8))
        #expect(!AppLauncher.isSettled(frames: [], now: 100, settleTime: 0))
    }

    @Test func oneSampleSettlesAfterTheSettleTime() {
        let history = [sample(10, a)]
        #expect(!AppLauncher.isSettled(frames: history, now: 10.5, settleTime: 0.8))
        #expect(AppLauncher.isSettled(frames: history, now: 10.8, settleTime: 0.8))
        #expect(AppLauncher.isSettled(frames: history, now: 12, settleTime: 0.8))
    }

    @Test func zeroSettleTimeIsSettledAtOnce() {
        #expect(AppLauncher.isSettled(frames: [sample(10, a)], now: 10, settleTime: 0))
    }

    @Test func aChangeStartsTheWaitAgain() {
        // The window was moved by the app at t = 11.
        let history = [sample(10, a), sample(10.5, a), sample(11, b), sample(11.1, b)]
        #expect(!AppLauncher.isSettled(frames: history, now: 11.5, settleTime: 0.8))
        #expect(AppLauncher.isSettled(frames: history, now: 11.8, settleTime: 0.8))
    }

    @Test func aChangeAndBackStillCountsAsAChange() {
        let history = [sample(10, a), sample(10.4, b), sample(10.8, a)]
        #expect(!AppLauncher.isSettled(frames: history, now: 11.2, settleTime: 0.8))
        #expect(AppLauncher.isSettled(frames: history, now: 11.65, settleTime: 0.8))
    }

    @Test func theRunIsMeasuredFromItsFirstSampleNotTheLast() {
        // Many identical samples: the run started at t = 10, not at the latest poll.
        let history = (0...8).map { sample(10 + Double($0) * 0.1, a) }
        #expect(AppLauncher.isSettled(frames: history, now: 10.8, settleTime: 0.8))
        #expect(!AppLauncher.isSettled(frames: history, now: 10.79, settleTime: 0.8))
    }

    @Test func aNewWindowStartsTheWaitAgain() {
        let history = [sample(10, a), sample(10.5, a), sample(10.9, a, b)]
        #expect(!AppLauncher.isSettled(frames: history, now: 11.5, settleTime: 0.8))
        #expect(AppLauncher.isSettled(frames: history, now: 11.75, settleTime: 0.8))
    }

    @Test func aClosedWindowStartsTheWaitAgain() {
        // A splash screen closes and the main window stays.
        let history = [sample(10, a, b), sample(10.5, a, b), sample(10.6, b)]
        #expect(!AppLauncher.isSettled(frames: history, now: 11.2, settleTime: 0.8))
        #expect(AppLauncher.isSettled(frames: history, now: 11.4, settleTime: 0.8))
    }

    @Test func theOrderOfWindowsInASampleDoesNotMatter() {
        let history = [sample(10, a, b), sample(10.3, b, a), sample(10.6, a, b)]
        #expect(AppLauncher.isSettled(frames: history, now: 10.8, settleTime: 0.8))
    }

    @Test func tinyDifferencesAreIgnored() {
        let jitter = CGRect(x: a.minX + 0.3, y: a.minY - 0.3, width: a.width + 0.2, height: a.height)
        let history = [sample(10, a), sample(10.4, jitter), sample(10.8, a)]
        #expect(AppLauncher.isSettled(frames: history, now: 10.8, settleTime: 0.8))
    }

    @Test func bigDifferencesAreNotIgnored() {
        let moved = CGRect(x: a.minX + 2, y: a.minY, width: a.width, height: a.height)
        let history = [sample(10, a), sample(10.4, moved)]
        #expect(!AppLauncher.isSettled(frames: history, now: 10.8, settleTime: 0.8))
    }

    @Test func aWiderToleranceCanBeGiven() {
        let moved = CGRect(x: a.minX + 2, y: a.minY, width: a.width, height: a.height)
        let history = [sample(10, a), sample(10.4, moved)]
        #expect(AppLauncher.isSettled(frames: history, now: 10.8, settleTime: 0.8, tolerance: 3))
    }

    @Test func sizeChangesCountToo() {
        let resized = CGRect(x: a.minX, y: a.minY, width: a.width + 40, height: a.height)
        #expect(!AppLauncher.isSettled(frames: [sample(10, a), sample(10.5, resized)], now: 11, settleTime: 0.8))
    }

    @Test func aWindowListThatStaysEmptyCanSettleToo() {
        #expect(AppLauncher.isSettled(frames: [sample(10), sample(10.5)], now: 11, settleTime: 0.8))
    }

    @Test func pollingTraceOfAnElectronApp() {
        // Window appears at t = 2.0, the app resizes it at 2.6 and 3.1, then leaves it alone.
        var history: [AppLauncher.FrameSample] = []
        let small = rect(0, 0, 400, 300)
        let medium = rect(0, 0, 900, 600)
        let large = rect(40, 40, 1400, 900)
        var settledAt: TimeInterval?
        var time = 2.0
        while time < 6 {
            let frame = time < 2.6 ? small : (time < 3.1 ? medium : large)
            history.append(sample(time, frame))
            if settledAt == nil, AppLauncher.isSettled(frames: history, now: time, settleTime: 0.8) {
                settledAt = time
            }
            time += 0.1
        }
        #expect(settledAt != nil)
        // Last change at 3.1, so settled about 0.8 s later.
        #expect(abs((settledAt ?? 0) - 3.9) < 0.25)
    }
}

// MARK: - resolveURL

@Suite struct AppLauncherResolveTests {
    @Test func bundleIDLookupWins() throws {
        let temp = try TempFolder()
        let installed = try temp.makeApp("Installed", in: try temp.folder("lookup"))
        let saved = try temp.makeApp("Saved", in: try temp.folder("saved"))
        let launcher = makeLauncher(searching: [], lookup: ["com.example.app": installed])
        let app = AppRef(bundleID: "com.example.app", name: "Example", path: saved.path)
        #expect(launcher.resolveURL(for: app) == installed)
    }

    @Test func savedPathIsUsedWhenTheBundleIDIsUnknown() throws {
        let temp = try TempFolder()
        let saved = try temp.makeApp("Saved", in: try temp.folder("saved"))
        let launcher = makeLauncher(searching: [])
        let app = AppRef(bundleID: "com.example.gone", name: "Example", path: saved.path)
        #expect(launcher.resolveURL(for: app)?.path == saved.path)
    }

    @Test func savedPathIsUsedWithoutABundleID() throws {
        let temp = try TempFolder()
        let saved = try temp.makeApp("Saved", in: try temp.folder("saved"))
        let launcher = makeLauncher(searching: [])
        #expect(launcher.resolveURL(for: AppRef(bundleID: nil, name: "Whatever", path: saved.path))?.path == saved.path)
    }

    @Test func aLookupResultThatNoLongerExistsFallsThrough() throws {
        let temp = try TempFolder()
        let missing = temp.url.appendingPathComponent("Deleted.app", isDirectory: true)
        let saved = try temp.makeApp("Saved", in: try temp.folder("saved"))
        let launcher = makeLauncher(searching: [], lookup: ["com.example.app": missing])
        let app = AppRef(bundleID: "com.example.app", name: "Example", path: saved.path)
        #expect(launcher.resolveURL(for: app)?.path == saved.path)
    }

    @Test func nameSearchIsTheLastResort() throws {
        let temp = try TempFolder()
        let applications = try temp.folder("Applications")
        let found = try temp.makeApp("Example", in: applications)
        let launcher = makeLauncher(searching: [applications])
        let app = AppRef(bundleID: "com.example.gone", name: "Example", path: temp.url.appendingPathComponent("Gone.app").path)
        #expect(launcher.resolveURL(for: app)?.path == found.path)
    }

    @Test func searchFoldersAreTriedInOrder() throws {
        let temp = try TempFolder()
        let first = try temp.folder("first")
        let second = try temp.folder("second")
        let inFirst = try temp.makeApp("Example", in: first)
        try temp.makeApp("Example", in: second)
        #expect(makeLauncher(searching: [first, second]).resolveURL(for: AppRef(bundleID: nil, name: "Example"))?.path == inFirst.path)

        let onlyInSecond = try temp.makeApp("Other", in: second)
        #expect(makeLauncher(searching: [first, second]).resolveURL(for: AppRef(bundleID: nil, name: "Other"))?.path == onlyInSecond.path)
    }

    @Test func nameMatchIgnoresCaseAndAnAppSuffix() throws {
        let temp = try TempFolder()
        let applications = try temp.folder("Applications")
        let found = try temp.makeApp("Visual Studio Code", in: applications)
        let launcher = makeLauncher(searching: [applications])
        #expect(launcher.resolveURL(for: AppRef(bundleID: nil, name: "visual studio code"))?.path == found.path)
        #expect(launcher.resolveURL(for: AppRef(bundleID: nil, name: "Visual Studio Code.app"))?.path == found.path)
        #expect(launcher.resolveURL(for: AppRef(bundleID: nil, name: "  Visual Studio Code "))?.path == found.path)
    }

    @Test func nameSearchSkipsAnAppWithAnotherBundleID() throws {
        let temp = try TempFolder()
        let first = try temp.folder("first")
        let second = try temp.folder("second")
        try temp.makeApp("Code", in: first, bundleID: "com.other.code")
        let right = try temp.makeApp("Code", in: second, bundleID: "com.microsoft.VSCode")
        let launcher = makeLauncher(searching: [first, second])
        let app = AppRef(bundleID: "com.microsoft.VSCode", name: "Code")
        #expect(launcher.resolveURL(for: app)?.path == right.path)

        let none = AppRef(bundleID: "com.unrelated.thing", name: "Code")
        #expect(launcher.resolveURL(for: none) == nil)
    }

    @Test func nameSearchWithoutABundleIDAcceptsAnyApp() throws {
        let temp = try TempFolder()
        let applications = try temp.folder("Applications")
        let found = try temp.makeApp("Code", in: applications, bundleID: "com.microsoft.VSCode")
        #expect(makeLauncher(searching: [applications]).resolveURL(for: AppRef(bundleID: nil, name: "Code"))?.path == found.path)
    }

    @Test func nothingFoundGivesNil() throws {
        let temp = try TempFolder()
        let applications = try temp.folder("Applications")
        let launcher = makeLauncher(searching: [applications, temp.url.appendingPathComponent("not-there")])
        #expect(launcher.resolveURL(for: AppRef(bundleID: "com.example.gone", name: "Gone", path: "/no/such/Gone.app")) == nil)
        #expect(launcher.resolveURL(for: AppRef(bundleID: nil, name: "")) == nil)
        #expect(launcher.resolveURL(for: AppRef(bundleID: nil, name: "a/b")) == nil)
    }

    @Test func aFileIsNotAnApp() throws {
        let temp = try TempFolder()
        let applications = try temp.folder("Applications")
        let file = applications.appendingPathComponent("Fake.app")
        try Data("x".utf8).write(to: file)
        #expect(makeLauncher(searching: [applications]).resolveURL(for: AppRef(bundleID: nil, name: "Fake")) == nil)
        #expect(makeLauncher(searching: []).resolveURL(for: AppRef(bundleID: nil, name: "Fake", path: file.path)) == nil)
    }

    @Test func emptyBundleIDAndPathAreIgnored() throws {
        let temp = try TempFolder()
        let applications = try temp.folder("Applications")
        let found = try temp.makeApp("Example", in: applications)
        let app = AppRef(bundleID: "", name: "Example", path: "")
        #expect(makeLauncher(searching: [applications], lookup: ["": found]).resolveURL(for: app)?.path == found.path)
    }

    @Test func bundleLookupIsNotAskedWithoutABundleID() throws {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let launcher = AppLauncher(searchDirectories: [], bundleLookup: { _ in counter.calls += 1; return nil },
                                   runningApplications: { [] })
        _ = launcher.resolveURL(for: AppRef(bundleID: nil, name: "Nothing"))
        #expect(counter.calls == 0)
        _ = launcher.resolveURL(for: AppRef(bundleID: "com.example.app", name: "Nothing"))
        #expect(counter.calls == 1)
    }

    @Test func theInjectedFileManagerIsUsed() {
        let fake = FakeFileManager()
        fake.directories = ["/Fake/Applications", "/Fake/Applications/Notes.app", "/Fake/Saved/Old.app"]
        fake.listings = ["/Fake/Applications": ["Notes.app"]]
        let launcher = makeLauncher(searching: [URL(fileURLWithPath: "/Fake/Applications")], fileManager: fake)
        #expect(launcher.resolveURL(for: AppRef(bundleID: nil, name: "Notes"))?.path == "/Fake/Applications/Notes.app")
        #expect(launcher.resolveURL(for: AppRef(bundleID: nil, name: "Old", path: "/Fake/Saved/Old.app"))?.path == "/Fake/Saved/Old.app")
        #expect(launcher.resolveURL(for: AppRef(bundleID: nil, name: "Mail")) == nil)
    }

    @Test func caseInsensitiveListingWorksOnCaseSensitiveVolumes() {
        let fake = FakeFileManager()
        fake.directories = ["/Fake/Applications", "/Fake/Applications/NOTES.app"]
        fake.listings = ["/Fake/Applications": ["NOTES.app", "Other.app"]]
        let launcher = makeLauncher(searching: [URL(fileURLWithPath: "/Fake/Applications")], fileManager: fake)
        #expect(launcher.resolveURL(for: AppRef(bundleID: nil, name: "Notes"))?.path == "/Fake/Applications/NOTES.app")
    }

    @Test func defaultSearchFolders() {
        let paths = AppLauncher.defaultSearchDirectories.map(\.path)
        #expect(paths.prefix(3).elementsEqual([
            "/Applications", "/System/Applications",
            NSString(string: "~/Applications").expandingTildeInPath,
        ]))
        #expect(!paths.contains { $0.contains("~") })
        #expect(AppLauncher().searchDirectories == AppLauncher.defaultSearchDirectories)
    }
}

// MARK: - isRunning and matching

@Suite struct AppLauncherRunningTests {
    @Test func bundleIDMatchIgnoresCase() {
        let app = AppRef(bundleID: "com.Microsoft.VSCode", name: "Code")
        #expect(AppLauncher.matches(app, bundleID: "com.microsoft.vscode", localizedName: "Anything", bundleFileName: nil))
        #expect(!AppLauncher.matches(app, bundleID: "com.other.app", localizedName: "Code", bundleFileName: "Code.app"))
        #expect(!AppLauncher.matches(app, bundleID: nil, localizedName: "Code", bundleFileName: "Code.app"))
    }

    @Test func nameMatchIsUsedWithoutABundleID() {
        let app = AppRef(bundleID: nil, name: "Telegram")
        #expect(AppLauncher.matches(app, bundleID: "ru.keepcoder.Telegram", localizedName: "telegram", bundleFileName: nil))
        #expect(AppLauncher.matches(app, bundleID: nil, localizedName: nil, bundleFileName: "Telegram.app"))
        #expect(!AppLauncher.matches(app, bundleID: nil, localizedName: "Telegram Helper", bundleFileName: "Telegram Helper.app"))
        #expect(!AppLauncher.matches(AppRef(bundleID: nil, name: ""), bundleID: nil, localizedName: "", bundleFileName: ""))
    }

    @Test func nothingRunningMeansNil() {
        let launcher = AppLauncher(searchDirectories: [], bundleLookup: { _ in nil }, runningApplications: { [] })
        #expect(launcher.isRunning(AppRef(bundleID: "com.example.app", name: "Example")) == nil)
    }

    @Test func thisProcessIsFoundByItsOwnIdentity() {
        let current = NSRunningApplication.current
        let launcher = AppLauncher(searchDirectories: [], bundleLookup: { _ in nil },
                                   runningApplications: { [NSRunningApplication.current] })
        #expect(launcher.isRunning(AppRef(bundleID: "no.such.bundle.id", name: "No Such App")) == nil)
        if let id = current.bundleIdentifier {
            #expect(launcher.isRunning(AppRef(bundleID: id, name: "different name"))?.processIdentifier == current.processIdentifier)
        }
        if let name = current.localizedName, !name.isEmpty {
            #expect(launcher.isRunning(AppRef(bundleID: nil, name: name))?.processIdentifier == current.processIdentifier)
        }
    }
}

// MARK: - launch / launchAll without apps

@Suite struct AppLauncherLaunchTests {
    private func emptyLauncher() -> AppLauncher {
        AppLauncher(searchDirectories: [], bundleLookup: { _ in nil }, runningApplications: { [] })
    }

    @Test func anAppThatDoesNotExistIsReportedNotFound() async {
        let app = AppRef(bundleID: "com.example.missing", name: "Missing", path: "/no/such/Missing.app")
        let result = await emptyLauncher().launch(app)
        #expect(result.status == .notFound)
        #expect(result.app == app)
        #expect(result.pid == nil)
        #expect(result.windowCount == 0)
        #expect(!result.isRunning)
    }

    @Test func launchAllKeepsTheOrderOfTheInput() async {
        let apps = (0..<7).map { AppRef(bundleID: "com.example.missing\($0)", name: "Missing \($0)") }
        let results = await emptyLauncher().launchAll(apps, concurrency: 3)
        #expect(results.map(\.app) == apps)
        #expect(results.allSatisfy { $0.status == .notFound })
    }

    @Test func launchAllOfNothingIsEmpty() async {
        #expect(await emptyLauncher().launchAll([]).isEmpty)
    }

    @Test func launchAllToleratesNonsenseConcurrency() async {
        let apps = [AppRef(bundleID: "a", name: "A"), AppRef(bundleID: "b", name: "B")]
        #expect(await emptyLauncher().launchAll(apps, concurrency: 0).count == 2)
        #expect(await emptyLauncher().launchAll(apps, concurrency: -5).count == 2)
        #expect(await emptyLauncher().launchAll(apps, concurrency: 100).count == 2)
    }

    @Test func anAppListedTwiceGetsOneResultPerEntry() async {
        let first = AppRef(bundleID: "com.example.Same", name: "Same")
        let second = AppRef(bundleID: "COM.EXAMPLE.SAME", name: "Same (copy)", path: nil)
        let other = AppRef(bundleID: nil, name: "Other")
        let results = await emptyLauncher().launchAll([first, other, second, other])
        #expect(results.map(\.app) == [first, other, second, other])
        #expect(results.allSatisfy { $0.status == .notFound })
    }

    @Test func perAppOptionsAreAskedForEveryUniqueApp() async {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var names: [String] = []
            func add(_ name: String) { lock.withLock { names.append(name) } }
        }
        let seen = Seen()
        let apps = [AppRef(bundleID: "a", name: "A"), AppRef(bundleID: "b", name: "B"), AppRef(bundleID: "a", name: "A")]
        let results = await emptyLauncher().launchAll(apps, concurrency: 2) { app in
            seen.add(app.name)
            return LaunchOptions(minWindows: 2)
        }
        #expect(results.count == 3)
        #expect(seen.names.sorted() == ["A", "B"])
    }
}
