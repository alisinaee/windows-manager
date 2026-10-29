import Foundation
import AppKit

// `wm updates check`: read-only. The app updates with Sparkle, which only the app links. This reads the same
// SUFeedURL from the installed app's Info.plist, fetches the appcast and compares versions. It never downloads
// or installs anything.

public struct AppcastItem: Equatable, Codable {
    public var version: String          // build number (sparkle:version)
    public var shortVersion: String?    // sparkle:shortVersionString
    public var downloadURL: String?
}

public struct UpdateCheckResult: Codable, Equatable {
    public var configured: Bool
    public var appPath: String?
    public var feedURL: String?
    public var currentVersion: String?
    public var currentBuild: String?
    public var latestVersion: String?
    public var latestBuild: String?
    public var updateAvailable: Bool?
    public var downloadURL: String?
}

public enum UpdateCheck {
    public static let appBundleID = "dev.windowsmanager.WindowsManager"

    /// The trimmed SUFeedURL, or nil when it is missing or empty (the app then never contacts a server).
    public static func feedURL(info: [String: Any]) -> String? {
        let t = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? t : nil
    }

    /// Compares dotted numeric versions ("1.10" > "1.9"); non-numeric parts compare as 0.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func parseAppcast(_ data: Data) -> [AppcastItem] {
        final class Parser: NSObject, XMLParserDelegate {
            var items: [AppcastItem] = []
            var current: AppcastItem?
            var text = ""
            func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
                text = ""
                if name == "item" { current = AppcastItem(version: "") }
                if name == "enclosure", current != nil {
                    current?.downloadURL = a["url"]
                    if let v = a["sparkle:version"], current?.version.isEmpty == true { current?.version = v }
                    if let v = a["sparkle:shortVersionString"], current?.shortVersion == nil { current?.shortVersion = v }
                }
            }
            func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
            func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if name == "sparkle:version", !t.isEmpty { current?.version = t }
                if name == "sparkle:shortVersionString", !t.isEmpty { current?.shortVersion = t }
                if name == "item", let c = current { if !c.version.isEmpty { items.append(c) }; current = nil }
            }
        }
        let parser = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.items
    }

    /// The newest item by build number, or nil for an empty appcast.
    public static func newest(_ items: [AppcastItem]) -> AppcastItem? {
        items.max { compare($0.version, $1.version) == .orderedAscending }
    }

    public static func result(appPath: String?, info: [String: Any], appcast: Data?) -> UpdateCheckResult {
        let build = info["CFBundleVersion"] as? String
        var r = UpdateCheckResult(configured: feedURL(info: info) != nil, appPath: appPath, feedURL: feedURL(info: info),
                                  currentVersion: info["CFBundleShortVersionString"] as? String, currentBuild: build)
        guard let data = appcast, let latest = newest(parseAppcast(data)) else { return r }
        r.latestVersion = latest.shortVersion ?? latest.version
        r.latestBuild = latest.version
        r.downloadURL = latest.downloadURL
        r.updateAvailable = build.map { compare($0, latest.version) == .orderedAscending }
        return r
    }

    /// The installed app: `--app` path, else Launch Services' answer for the app's bundle id.
    public static func liveAppLocator() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID)
    }

    public static func liveFetch(_ url: URL) throws -> Data {
        try fetchSync(url, wait: 20) { request, done in
            URLSession.shared.dataTask(with: request) { data, response, error in done(data, response, error) }.resume()
        }
    }

    /// Blocks up to `wait` seconds for `start`'s completion. Only the first outcome counts: a callback that arrives after
    /// the timeout is ignored and never touches the returned value.
    static func fetchSync(_ url: URL, wait: TimeInterval,
                          start: (URLRequest, @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> Void) throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("wm-cli", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        let box = FetchBox()
        start(request) { data, response, error in
            let result: Result<Data, Error>
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(ServiceError.failed("The appcast server answered \(http.statusCode)."))
            } else { result = .success(data ?? Data()) }
            if box.set(result) { sem.signal() }
        }
        _ = sem.wait(timeout: .now() + wait)
        return try box.close().get()
    }

    private final class FetchBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Data, Error>?
        private var closed = false
        func set(_ r: Result<Data, Error>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !closed, value == nil else { return false }
            value = r
            return true
        }
        /// Takes the result and ignores every later write.
        func close() -> Result<Data, Error> {
            lock.lock(); defer { lock.unlock() }
            closed = true
            return value ?? .failure(ServiceError.failed("No response."))
        }
    }
}

public enum UpdateCommands {
    public static func register(_ r: Registry, locate: @escaping () -> URL?, fetch: @escaping (URL) throws -> Data) {
        r.register(Command(["updates", "check"], summary: "Check the appcast for a newer version (read-only; does not download or install)",
                           options: [CLIOption("app", "Path of the installed app (default: found by bundle id)", takesValue: true, valueName: "path")]) { a, _ in
            let appURL = a.value("app").map { URL(fileURLWithPath: $0) } ?? locate()
            guard let appURL else {
                throw CLIFailure.notFound("Windows Manager is not installed where Launch Services can find it.", hint: "Pass --app <path to the .app>")
            }
            let plist = appURL.appendingPathComponent("Contents/Info.plist")
            guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else {
                throw CLIFailure.notFound("No Info.plist at \(plist.path).", hint: "Pass --app <path to the .app>")
            }
            var data: Data?
            if let feed = UpdateCheck.feedURL(info: info) {
                guard let url = URL(string: feed), url.scheme == "https" || url.scheme == "http" else {
                    throw CLIFailure(.runtime, code: "bad_feed", message: "SUFeedURL \"\(feed)\" is not a web address.")
                }
                do { data = try fetch(url) } catch {
                    throw CLIFailure(.runtime, code: "fetch_failed", message: "Could not read the appcast: \(error.localizedDescription)")
                }
            }
            let result = UpdateCheck.result(appPath: appURL.path, info: info, appcast: data)
            let text: String
            if !result.configured { text = "Updates are not configured yet (no SUFeedURL in the app)." }
            else if result.latestBuild == nil { text = "The appcast has no versions." }
            else if result.updateAvailable == true { text = "Update available: \(result.latestVersion ?? "") (current \(result.currentVersion ?? "?"))" }
            else { text = "Up to date (\(result.currentVersion ?? "?"))." }
            return CLIResult(data: try JSONValue.from(result), text: text)
        })
    }
}
