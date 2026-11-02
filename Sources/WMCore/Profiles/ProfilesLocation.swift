import Foundation

// Where profiles live (P8.4). The user can pick a folder (iCloud Drive, Dropbox, ...) so two Macs share
// their profiles. The choice is the `profilesFolder` preference of the app's domain, read through
// CFPreferences so the app and the `wm` CLI see the same value. Nil means the default location.

public enum ProfilesLocation {
    public static let preferenceKey = "profilesFolder"
    public static let appDomain = "dev.windowsmanager.WindowsManager"

    /// The folder to use: `WM_PROFILES_DIR` first, then the chosen folder, then `fallback`.
    public static func resolve(environment: [String: String], preference: String?, fallback: URL) -> URL {
        if let dir = environment["WM_PROFILES_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        if let path = preference?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return fallback
    }

    /// The chosen folder path, or nil when the default location is used.
    public static var configuredPath: String? {
        CFPreferencesCopyAppValue(preferenceKey as CFString, appDomain as CFString) as? String
    }

    /// Stores the chosen folder; nil resets to the default location.
    public static func setConfiguredPath(_ path: String?) {
        CFPreferencesSetAppValue(preferenceKey as CFString, path as CFString?, appDomain as CFString)
        CFPreferencesAppSynchronize(appDomain as CFString)
    }

    /// Copies profile files from `source` into `destination`, never overwriting a file that exists there and
    /// never touching `source`. Returns the number of files copied. Trash and iCloud placeholders stay behind.
    @discardableResult
    public static func migrate(from source: URL, to destination: URL, fileManager: FileManager = .default) throws -> Int {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return 0 }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: source.path)) ?? []
        var copied = 0
        for name in names.sorted() where name.lowercased().hasSuffix(".json") && !name.hasPrefix(".") {
            let from = source.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: from.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let to = destination.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: to.path) else { continue }
            try fileManager.copyItem(at: from, to: to)
            copied += 1
        }
        return copied
    }

    /// An iCloud placeholder for a file that is not downloaded yet: `.<name>.icloud`.
    public static func isICloudPlaceholder(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".icloud")
    }

    /// A sync conflict copy: a json file whose stem is a profile id followed by extra text
    /// ("<id> 2.json", "<id> (conflicted copy).json").
    public static func isConflictCopy(_ name: String) -> Bool {
        guard name.lowercased().hasSuffix(".json"), !name.hasPrefix(".") else { return false }
        let stem = String(name.dropLast(5))
        guard stem.count > 36, UUID(uuidString: String(stem.prefix(36))) != nil else { return false }
        return true
    }
}

/// Calls `onChange` (on the main queue) about a second after files in the folder change.
public final class ProfileFolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval
    private let onChange: () -> Void

    public init(debounce: TimeInterval = 1.0, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    /// Starts watching `folder`. Does nothing when it does not exist yet.
    public func start(folder: URL) {
        stop()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: .main)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
