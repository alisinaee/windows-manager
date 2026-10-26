import Foundation

// Layouts on disk (phase P4.2): one JSON file, <folder>/layouts.json, next to the Profiles folder in
// `~/Library/Application Support/WindowsManager/`. Written to a temp file and swapped in, so a crash
// never leaves a half-written file.

public enum LayoutStoreError: Error, LocalizedError, Equatable {
    case corrupt(String)
    case unsupportedSchema(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let reason): return "layouts.json is not readable: \(reason)"
        case .unsupportedSchema(let found, let supported):
            return "layouts.json uses schema \(found); this version reads up to \(supported)."
        }
    }
}

public final class LayoutStore: @unchecked Sendable {
    public static let schemaVersion = 1

    /// `~/Library/Application Support/WindowsManager/Layouts/`.
    public static var defaultFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("WindowsManager", isDirectory: true)
            .appendingPathComponent("Layouts", isDirectory: true)
    }

    private struct FileContent: Codable {
        var schema: Int
        var layouts: [Layout]
    }

    public let folder: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(folder: URL? = nil, fileManager: FileManager = .default) {
        self.folder = folder ?? Self.defaultFolder
        self.fileManager = fileManager
    }

    public var fileURL: URL { folder.appendingPathComponent("layouts.json", isDirectory: false) }

    /// All saved layouts, in saved order. A missing file is an empty list.
    public func load() throws -> [Layout] {
        lock.lock(); defer { lock.unlock() }
        return try read()
    }

    /// Replaces the saved layouts.
    public func save(_ layouts: [Layout]) throws {
        lock.lock(); defer { lock.unlock() }
        try write(layouts)
    }

    /// Adds a layout, or replaces the one with the same id.
    public func upsert(_ layout: Layout) throws {
        lock.lock(); defer { lock.unlock() }
        var all = try read()
        if let i = all.firstIndex(where: { $0.id == layout.id }) { all[i] = layout } else { all.append(layout) }
        try write(all)
    }

    public func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var all = try read()
        all.removeAll { $0.id == id }
        try write(all)
    }

    private func read() throws -> [Layout] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw LayoutStoreError.corrupt(error.localizedDescription) }
        do {
            let content = try JSONDecoder().decode(FileContent.self, from: data)
            guard content.schema >= 1, content.schema <= Self.schemaVersion else {
                throw LayoutStoreError.unsupportedSchema(found: content.schema, supported: Self.schemaVersion)
            }
            return content.layouts
        } catch let error as LayoutStoreError {
            throw error
        } catch {
            throw LayoutStoreError.corrupt(error.localizedDescription)
        }
    }

    private func write(_ layouts: [Layout]) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileContent(schema: Self.schemaVersion, layouts: layouts))
        let temp = folder.appendingPathComponent(".layouts-\(UUID().uuidString).tmp")
        try data.write(to: temp)
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: fileURL)
        }
    }
}
