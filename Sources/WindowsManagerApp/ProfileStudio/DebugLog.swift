import Foundation
import SwiftUI

/// Optional file log for debugging the Studio. Off by default; the switch lives in the Studio bottom bar.
/// Thread-safe: every write goes through one serial queue.
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()
    static let defaultsKey = "debugLogEnabled"
    static let maxBytes = 2 * 1024 * 1024

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Windows Manager/debug.log")
    }

    private let queue = DispatchQueue(label: "debug-log")

    static func log(_ category: String, _ message: String) {
        guard isEnabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(category)] \(message)\n"
        AppInfo.logger.notice("[\(category, privacy: .public)] \(message, privacy: .public)")
        shared.queue.async { shared.append(line) }
    }

    private func append(_ line: String) {
        let fm = FileManager.default
        let url = Self.logURL
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

/// Publishes the debug switch to SwiftUI.
@MainActor
final class DebugLogSettings: ObservableObject {
    @Published var isEnabled: Bool = DebugLog.isEnabled {
        didSet {
            guard isEnabled != DebugLog.isEnabled else { return }
            if isEnabled { DebugLog.isEnabled = true; DebugLog.log("studio", "debug log enabled") }
            else { DebugLog.log("studio", "debug log disabled"); DebugLog.isEnabled = false }
        }
    }
}

/// The "Debug log" switch shown at the right end of the Studio bottom bar.
struct DebugLogToggle: View {
    @StateObject private var settings = DebugLogSettings()

    var body: some View {
        Toggle("Debug log", isOn: $settings.isEnabled)
            .toggleStyle(.switch).controlSize(.small)
            .help(DebugLog.logURL.path)
    }
}
