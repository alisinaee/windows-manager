import Foundation

/// Process exit codes of the `wm` CLI.
public enum CLIExitCode: Int32, Sendable {
    case ok = 0, runtime = 1, usage = 2, notFound = 3, permission = 4, appNotRunning = 5, partial = 6
}

/// Minimal Codable JSON value so handlers can return arbitrary data.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), int(Int), double(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Converts any Encodable into a JSONValue.
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

public struct CLIErrorInfo: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var hint: String?
    public init(code: String, message: String, hint: String? = nil) {
        self.code = code; self.message = message; self.hint = hint
    }
}

/// `{"ok":true,"data":...}` or `{"ok":false,"error":{code,message,hint}}`.
public struct CLIEnvelope: Codable, Equatable, Sendable {
    public var ok: Bool
    public var data: JSONValue?
    public var error: CLIErrorInfo?

    public static func success(_ data: JSONValue = .null) -> CLIEnvelope { .init(ok: true, data: data, error: nil) }
    public static func failure(code: String, message: String, hint: String? = nil) -> CLIEnvelope {
        .init(ok: false, data: nil, error: CLIErrorInfo(code: code, message: message, hint: hint))
    }

    public func jsonString(pretty: Bool = false) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let d = try? enc.encode(self), let s = String(data: d, encoding: .utf8) else {
            return #"{"ok":false,"error":{"code":"encode","message":"envelope encoding failed"}}"#
        }
        return s
    }
}

/// Writes one JSON object per line: `{"event":"progress",...}`.
public struct NDJSONEventWriter {
    private let sink: (String) -> Void
    public init(sink: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }) {
        self.sink = sink
    }
    public func emit(_ event: String, _ fields: [String: JSONValue] = [:]) {
        var obj = fields
        obj["event"] = .string(event)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(JSONValue.object(obj)), let s = String(data: d, encoding: .utf8) { sink(s) }
    }
}
