import AppKit
import Foundation

// Content restore (phase P6.2): after the apps are running, reopen what they had open - documents,
// VS Code folders and browser tabs. Planning is pure; opening goes through `ContentOpening`.
// Browser tab URLs are not part of `Profile`; they live in a separate sidecar, `ContentSnapshot`.

/// What to reopen for one window.
public enum ContentItem: Equatable, Hashable, Sendable {
    case document(URL)
    case vscodeFolder(String)
    case browserTabs([URL])

    /// Stable key for the idempotence check ("already opened by us").
    public var key: String {
        switch self {
        case .document(let url): return "doc:" + url.standardizedFileURL.path
        case .vscodeFolder(let path): return "folder:" + (path as NSString).standardizingPath
        case .browserTabs(let urls): return "tabs:" + urls.map(\.absoluteString).joined(separator: "\n")
        }
    }
}

/// Browser tab URLs captured per window, keyed by the window's index in `Profile.windows`.
/// Stored next to a profile, never inside it.
public struct ContentSnapshot: Codable, Equatable, Sendable {
    public var tabURLs: [Int: [String]]

    public init(tabURLs: [Int: [String]] = [:]) {
        self.tabURLs = tabURLs
    }
}

/// One planned item with the window and app it belongs to.
public struct PlannedContent: Equatable, Sendable {
    public var windowIndex: Int
    public var app: AppRef
    public var item: ContentItem
    public init(windowIndex: Int, app: AppRef, item: ContentItem) {
        self.windowIndex = windowIndex
        self.app = app
        self.item = item
    }
}

/// Result of planning: items plus notes about windows that could not be turned into content.
public struct ContentPlan: Equatable, Sendable {
    public var items: [PlannedContent] = []
    public var warnings: [String] = []
    public init(items: [PlannedContent] = [], warnings: [String] = []) {
        self.items = items
        self.warnings = warnings
    }
}

public enum ContentKind {
    public static let vscodeFamily: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.vscodium", "com.exafunction.windsurf", "com.visualstudio.code.oss",
    ]
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
    ]

    /// Turns a documentPath (plain path or file:// URL) into an absolute path, nil when unusable.
    public static func normalizedPath(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("file://") {
            guard let url = URL(string: s), url.isFileURL else { return nil }
            s = url.path
        }
        guard s.hasPrefix("/") else { return nil }
        return (s as NSString).standardizingPath
    }

    /// Folder name from a title like "file — folder — Visual Studio Code" (also "-" separators).
    public static func folderName(fromTitle title: String?) -> String? {
        guard let title else { return nil }
        let parts = title.replacingOccurrences(of: " — ", with: "\u{1}")
            .replacingOccurrences(of: " – ", with: "\u{1}")
            .replacingOccurrences(of: " - ", with: "\u{1}")
            .components(separatedBy: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        let name = parts[parts.count - 2]
        return name.isEmpty ? nil : name
    }

    /// Folder to open in a VS Code window: the ancestor of the document path named like the title's folder,
    /// else the document's own directory (or the path itself when it is a directory).
    public static func vscodeFolder(documentPath: String?, title: String?,
                                    isDirectory: (String) -> Bool = ContentKind.isDirectory) -> String? {
        guard let path = normalizedPath(documentPath) else { return nil }
        if isDirectory(path) { return path }
        let parent = (path as NSString).deletingLastPathComponent
        if let name = folderName(fromTitle: title) {
            var dir = parent
            while dir != "/" && !dir.isEmpty {
                if (dir as NSString).lastPathComponent == name { return dir }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return parent.isEmpty || parent == "/" ? nil : parent
    }

    public static func isDirectory(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }
}

/// Opens content in an app. Injectable so tests never touch the system.
public protocol ContentOpening {
    func openDocument(_ url: URL, with app: AppRef) throws
    func openFolder(_ path: String, with app: AppRef) throws
    func openURLs(_ urls: [URL], in browser: AppRef) throws
}

public struct ContentOpenError: Error, Equatable, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Real implementation: NSWorkspace for documents, `/usr/bin/open` for folders and URLs.
public struct SystemContentOpener: ContentOpening {
    public init() {}

    private func appURL(_ app: AppRef) -> URL? {
        if let id = app.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        if let p = app.path, FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        return nil
    }

    public func openDocument(_ url: URL, with app: AppRef) throws {
        guard let appURL = appURL(app) else { throw ContentOpenError("app not found: \(app.name)") }
        let sem = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: {
            let c = NSWorkspace.OpenConfiguration()
            c.activates = false
            return c
        }()) { _, error in
            box.error = error
            sem.signal()
        }
        if sem.wait(timeout: .now() + 15) == .timedOut { throw ContentOpenError("timed out opening \(url.lastPathComponent)") }
        if let e = box.error { throw ContentOpenError("\(e.localizedDescription)") }
    }

    public func openFolder(_ path: String, with app: AppRef) throws {
        try run(app: app, args: [path])
    }

    public func openURLs(_ urls: [URL], in browser: AppRef) throws {
        guard !urls.isEmpty else { return }
        try run(app: browser, args: urls.map(\.absoluteString))
    }

    private func run(app: AppRef, args: [String]) throws {
        var argv: [String] = []
        if let id = app.bundleID { argv += ["-b", id] } else if let p = app.path { argv += ["-a", p] } else { argv += ["-a", app.name] }
        argv += args
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = argv
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw ContentOpenError("open exited with \(p.terminationStatus) for \(app.name)") }
    }

    private final class ErrorBox: @unchecked Sendable { var error: Error? }
}

/// What a content restore did.
public struct ContentReport: Equatable, Sendable {
    public var opened: [String] = []
    public var skipped: [String] = []
    public var warnings: [String] = []
    public init(opened: [String] = [], skipped: [String] = [], warnings: [String] = []) {
        self.opened = opened
        self.skipped = skipped
        self.warnings = warnings
    }
}

public enum ContentRestorer {
    /// Pure planning from captured windows. `windows` index = key of `snapshot.tabURLs`.
    public static func plan(windows: [WindowSnapshot], snapshot: ContentSnapshot? = nil,
                            isDirectory: (String) -> Bool = ContentKind.isDirectory) -> ContentPlan {
        var plan = ContentPlan()
        var seen = Set<String>()
        func add(_ i: Int, _ app: AppRef, _ item: ContentItem) {
            if seen.insert(item.key).inserted { plan.items.append(PlannedContent(windowIndex: i, app: app, item: item)) }
        }
        for (i, w) in windows.enumerated() where w.restore {
            guard let id = w.app.bundleID else { continue }
            if ContentKind.vscodeFamily.contains(id) {
                if let folder = ContentKind.vscodeFolder(documentPath: w.documentPath, title: w.title, isDirectory: isDirectory) {
                    add(i, w.app, .vscodeFolder(folder))
                } else if let name = ContentKind.folderName(fromTitle: w.title) {
                    plan.warnings.append("\(w.app.name): folder \"\(name)\" has no known path, skipped")
                }
            } else if ContentKind.browsers.contains(id) {
                let urls = (snapshot?.tabURLs[i] ?? []).compactMap { URL(string: $0) }
                    .filter { ["http", "https", "file"].contains($0.scheme?.lowercased() ?? "") }
                if !urls.isEmpty { add(i, w.app, .browserTabs(urls)) }
            } else if let path = ContentKind.normalizedPath(w.documentPath) {
                add(i, w.app, .document(URL(fileURLWithPath: path)))
            }
        }
        return plan
    }

    /// Opens the planned content that is still missing.
    /// - Parameters:
    ///   - availableApps: bundle ids of apps that are running or were launched; others are skipped with a warning.
    ///   - liveWindows: windows open now; a document or folder already shown there is not opened again.
    ///   - alreadyOpened: keys (`ContentItem.key`) opened by an earlier run; also skipped.
    public static func restore(plan: ContentPlan, availableApps: Set<String>, liveWindows: [LiveWindow],
                               alreadyOpened: Set<String> = [], opener: ContentOpening,
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> ContentReport {
        var report = ContentReport(warnings: plan.warnings)
        var done = alreadyOpened
        for p in plan.items {
            let key = p.item.key
            if let id = p.app.bundleID, !availableApps.contains(id) {
                report.warnings.append("\(p.app.name) is not running, content skipped")
                continue
            }
            if done.contains(key) { report.skipped.append(key); continue }
            let live = liveWindows.filter { $0.app.bundleID == p.app.bundleID }
            do {
                switch p.item {
                case .document(let url):
                    let path = url.standardizedFileURL.path
                    if live.contains(where: { ContentKind.normalizedPath($0.documentPath) == path }) {
                        report.skipped.append(key); continue
                    }
                    guard fileExists(path) else { report.warnings.append("missing file: \(path)"); continue }
                    try opener.openDocument(url, with: p.app)
                case .vscodeFolder(let folder):
                    let name = (folder as NSString).lastPathComponent
                    let shown = live.contains { w in
                        if let d = ContentKind.normalizedPath(w.documentPath), d == folder || d.hasPrefix(folder + "/") { return true }
                        return ContentKind.folderName(fromTitle: w.title) == name
                    }
                    if shown { report.skipped.append(key); continue }
                    guard fileExists(folder) else { report.warnings.append("missing folder: \(folder)"); continue }
                    try opener.openFolder(folder, with: p.app)
                case .browserTabs(let urls):
                    try opener.openURLs(urls, in: p.app)
                }
                done.insert(key)
                report.opened.append(key)
            } catch {
                report.warnings.append("\(p.app.name): \(error)")
            }
        }
        return report
    }
}

/// Reads front-window tab URLs of Safari and Chrome through AppleScript. Off by default; never called by restore.
public enum ContentCapture {
    public static var isEnabled = false

    public static func frontTabURLs(bundleID: String) -> [String] {
        guard isEnabled else { return [] }
        let name: String
        switch bundleID {
        case "com.apple.Safari": name = "Safari"
        case "com.google.Chrome": name = "Google Chrome"
        default: return []
        }
        let source = "tell application \"\(name)\" to get URL of every tab of front window"
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return [] }
        let result = script.executeAndReturnError(&err)
        guard err == nil, result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
    }
}
