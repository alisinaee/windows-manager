import Foundation
import Testing
@testable import WMCore

@Suite struct ContentRestorerReviewTests {
    let safari = AppRef(bundleID: "com.apple.Safari", name: "Safari")
    let chrome = AppRef(bundleID: "com.google.Chrome", name: "Google Chrome")
    let code = AppRef(bundleID: "com.microsoft.VSCode", name: "Code")
    let xcodeLike = AppRef(bundleID: "com.example.EditorA", name: "EditorA")
    let macdownLike = AppRef(bundleID: "com.example.EditorB", name: "EditorB")

    func win(_ app: AppRef, title: String? = nil, doc: String? = nil) -> WindowSnapshot {
        WindowSnapshot(app: app, title: title, documentPath: doc, displayUUID: "d", frame: .zero, relativeFrame: .zero,
                       placement: .unknown, isFullScreen: false, isMinimized: false)
    }

    // Finding 8: the key must include the app, so the same URL in two browsers is planned twice.
    @Test func sameURLInTwoBrowsersBothPlanned() {
        let ws = [win(safari), win(chrome)]
        let snap = ContentSnapshot(tabURLs: [0: ["https://example.com"], 1: ["https://example.com"]])
        let plan = ContentRestorer.plan(windows: ws, snapshot: snap)
        #expect(plan.items.count == 2)
        #expect(plan.items.map(\.app) == [safari, chrome])
    }

    // Finding 8: two editors with the same document path are both restored.
    @Test func sameDocumentInTwoEditorsBothPlanned() {
        let ws = [win(xcodeLike, doc: "/work/p/a.txt"), win(macdownLike, doc: "/work/p/a.txt")]
        let plan = ContentRestorer.plan(windows: ws)
        #expect(plan.items.count == 2)
    }

    // Finding 8: idempotence keys differ per app, so an already-opened key from one app does not hide the other.
    @Test func alreadyOpenedKeyIsPerApp() {
        let ws = [win(safari), win(chrome)]
        let snap = ContentSnapshot(tabURLs: [0: ["https://example.com"], 1: ["https://example.com"]])
        let plan = ContentRestorer.plan(windows: ws, snapshot: snap)
        #expect(plan.items.count == 2)
        guard plan.items.count == 2 else { return }
        let safariKey = plan.items[0].item.key(app: safari)
        let chromeKey = plan.items[1].item.key(app: chrome)
        #expect(safariKey != chromeKey)
        let fake = ReviewOpener()
        let r = ContentRestorer.restore(plan: plan, availableApps: ["com.apple.Safari", "com.google.Chrome"],
                                        liveWindows: [], alreadyOpened: [safariKey], opener: fake,
                                        fileExists: { _ in true })
        #expect(fake.urls.count == 1)
        #expect(r.skipped == [safariKey])
        #expect(r.opened == [chromeKey])
    }

    // Finding 9: a VS Code title with a folder and no file is a folder, not a silent skip.
    @Test func vscodeFolderOnlyTitleWarnsWithoutPath() {
        let plan = ContentRestorer.plan(windows: [win(code, title: "my-project — Visual Studio Code")])
        #expect(plan.items.isEmpty)
        #expect(plan.warnings.count == 1)
        #expect(plan.warnings.first?.contains("my-project") == true)
    }

    // Finding 9: with a document path, the two-part title finds the matching ancestor folder.
    @Test func vscodeFolderOnlyTitleUsesAncestorWithPath() {
        let plan = ContentRestorer.plan(windows: [win(code, title: "my-project — Visual Studio Code",
                                                      doc: "/Users/x/my-project/src/a.swift")],
                                        isDirectory: { _ in false })
        #expect(plan.items.map(\.item) == [.vscodeFolder("/Users/x/my-project")])
    }

    // Finding 9: a title that is only the app name still yields nothing.
    @Test func appNameOnlyTitleIsIgnored() {
        let plan = ContentRestorer.plan(windows: [win(code, title: "Visual Studio Code")])
        #expect(plan.items.isEmpty)
        #expect(plan.warnings.isEmpty)
    }

    @Test func folderNameFromTwoPartTitle() {
        #expect(ContentKind.folderName(fromTitle: "my-project — Visual Studio Code") == "my-project")
        #expect(ContentKind.folderName(fromTitle: "Visual Studio Code") == nil)
    }
}

private final class ReviewOpener: ContentOpening {
    var urls: [[URL]] = []
    func openDocument(_ url: URL, with app: AppRef) throws {}
    func openFolder(_ path: String, with app: AppRef) throws {}
    func openURLs(_ u: [URL], in browser: AppRef) throws { urls.append(u) }
}
