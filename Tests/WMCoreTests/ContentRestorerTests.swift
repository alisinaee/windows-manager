import Foundation
import Testing
@testable import WMCore

private final class FakeOpener: ContentOpening {
    var docs: [URL] = [], folders: [String] = [], urls: [[URL]] = []
    var fail = false
    func openDocument(_ url: URL, with app: AppRef) throws { if fail { throw ContentOpenError("boom") }; docs.append(url) }
    func openFolder(_ path: String, with app: AppRef) throws { folders.append(path) }
    func openURLs(_ u: [URL], in browser: AppRef) throws { urls.append(u) }
}

@Suite struct ContentRestorerTests {
    let code = AppRef(bundleID: "com.microsoft.VSCode", name: "Code")
    let safari = AppRef(bundleID: "com.apple.Safari", name: "Safari")
    let pages = AppRef(bundleID: "com.apple.iWork.Pages", name: "Pages")

    func win(_ app: AppRef, title: String? = nil, doc: String? = nil) -> WindowSnapshot {
        WindowSnapshot(app: app, title: title, documentPath: doc, displayUUID: "d", frame: .zero, relativeFrame: .zero,
                       placement: .unknown, isFullScreen: false, isMinimized: false)
    }

    @Test func planDerivesItems() {
        let ws = [win(pages, doc: "file:///tmp/a.pages"),
                  win(code, title: "main.swift — proj — Visual Studio Code", doc: "/work/proj/src/main.swift"),
                  win(safari)]
        let plan = ContentRestorer.plan(windows: ws, snapshot: ContentSnapshot(tabURLs: [2: ["https://a.com", "bad"]]),
                                        isDirectory: { _ in false })
        #expect(plan.items.map(\.item) == [.document(URL(fileURLWithPath: "/tmp/a.pages")),
                                           .vscodeFolder("/work/proj"),
                                           .browserTabs([URL(string: "https://a.com")!])])
    }

    @Test func folderFromTitleWithoutPathWarns() {
        let plan = ContentRestorer.plan(windows: [win(code, title: "a — proj — Visual Studio Code")])
        #expect(plan.items.isEmpty && plan.warnings.count == 1)
    }

    @Test func restoreOpensOnceAndSkipsLive() {
        let ws = [win(pages, doc: "/tmp/a.pages"), win(pages, doc: "/tmp/b.pages")]
        let plan = ContentRestorer.plan(windows: ws)
        let live = [LiveWindow(windowID: 1, app: pages, documentPath: "/tmp/a.pages", frame: .zero)]
        let fake = FakeOpener()
        let r = ContentRestorer.restore(plan: plan, availableApps: ["com.apple.iWork.Pages"], liveWindows: live,
                                        opener: fake, fileExists: { _ in true })
        #expect(fake.docs == [URL(fileURLWithPath: "/tmp/b.pages")])
        #expect(r.skipped.count == 1 && r.opened.count == 1)
        let r2 = ContentRestorer.restore(plan: plan, availableApps: ["com.apple.iWork.Pages"], liveWindows: live,
                                         alreadyOpened: Set(r.opened), opener: fake, fileExists: { _ in true })
        #expect(r2.opened.isEmpty && fake.docs.count == 1)
    }

    @Test func warnsOnMissingFileAppAndError() {
        let plan = ContentRestorer.plan(windows: [win(pages, doc: "/tmp/a.pages")])
        let fake = FakeOpener()
        var r = ContentRestorer.restore(plan: plan, availableApps: [], liveWindows: [], opener: fake)
        #expect(r.warnings.count == 1)
        r = ContentRestorer.restore(plan: plan, availableApps: ["com.apple.iWork.Pages"], liveWindows: [],
                                    opener: fake, fileExists: { _ in false })
        #expect(r.warnings.first?.contains("missing file") == true)
        fake.fail = true
        r = ContentRestorer.restore(plan: plan, availableApps: ["com.apple.iWork.Pages"], liveWindows: [],
                                    opener: fake, fileExists: { _ in true })
        #expect(r.opened.isEmpty && r.warnings.count == 1)
    }

    @Test func browserAndFolderOpen() {
        let ws = [win(code, doc: "/w/p/x.swift"), win(safari)]
        let plan = ContentRestorer.plan(windows: ws, snapshot: ContentSnapshot(tabURLs: [1: ["https://a.com"]]),
                                        isDirectory: { _ in false })
        let fake = FakeOpener()
        let r = ContentRestorer.restore(plan: plan, availableApps: ["com.microsoft.VSCode", "com.apple.Safari"],
                                        liveWindows: [], opener: fake, fileExists: { _ in true })
        #expect(fake.folders == ["/w/p"] && fake.urls.count == 1 && r.opened.count == 2)
    }
}
