import Foundation

/// Newline-delimited JSON between the `wm` CLI and the running app.
/// Request: {"id","command","args"}. Response: {"id","ok","data"} or {"id","ok":false,"error":{code,message,hint}}.
public struct IPCRequest: Codable, Equatable, Sendable {
    public var id: String
    public var command: String
    public var args: [String: JSONValue]
    public init(id: String = UUID().uuidString, command: String, args: [String: JSONValue] = [:]) {
        self.id = id; self.command = command; self.args = args
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
    }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public var id: String
    public var ok: Bool
    public var data: JSONValue?
    public var error: CLIErrorInfo?

    public static func success(id: String, _ data: JSONValue = .null) -> IPCResponse {
        .init(id: id, ok: true, data: data, error: nil)
    }
    public static func failure(id: String, code: String, message: String, hint: String? = nil) -> IPCResponse {
        .init(id: id, ok: false, data: nil, error: CLIErrorInfo(code: code, message: message, hint: hint))
    }
}

public enum IPCError: Error, Equatable {
    case notRunning            // no socket, or nobody listening
    case timeout
    case badMessage(String)
    case io(String)
}

/// Pure encode/decode of one line.
public enum IPCCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var d = try e.encode(value)
        d.append(0x0A)
        return d
    }
    public static func decodeRequest(_ line: Data) throws -> IPCRequest {
        do { return try JSONDecoder().decode(IPCRequest.self, from: line) }
        catch { throw IPCError.badMessage("not a valid request: \(error.localizedDescription)") }
    }
    public static func decodeResponse(_ line: Data) throws -> IPCResponse {
        do { return try JSONDecoder().decode(IPCResponse.self, from: line) }
        catch { throw IPCError.badMessage("not a valid response: \(error.localizedDescription)") }
    }
}

/// Accumulates bytes and yields complete lines (without the newline).
public struct IPCLineBuffer {
    private var buffer = Data()
    public let maxLine: Int
    public init(maxLine: Int = 4 * 1024 * 1024) { self.maxLine = maxLine }
    public var overflowed: Bool { buffer.count > maxLine }
    public mutating func append(_ d: Data) { buffer.append(d) }
    public mutating func nextLine() -> Data? {
        guard let i = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = buffer[buffer.startIndex..<i]
        buffer = Data(buffer[buffer.index(after: i)...])
        return Data(line)
    }
}

public enum IPCPaths {
    public static var defaultSocketPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("WindowsManager/control.sock").path
    }
}
