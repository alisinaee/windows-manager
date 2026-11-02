import Foundation

/// Model Context Protocol server logic (JSON-RPC 2.0, newline-delimited stdio) for `wm mcp`.
/// Pure and testable: command execution and the agent guide are injected.
public final class MCPServer {
    public static let protocolVersion = "2025-06-18"

    /// Runs `wm <args>` and returns (stdout, exit code).
    public typealias Runner = (_ args: [String]) -> (output: String, exit: Int32)

    private let commands: [Command]
    private let version: String
    private let guide: String
    private let runner: Runner

    public init(commands: [Command], version: String, agentGuide: String, runner: @escaping Runner) {
        self.commands = commands.filter { $0.path != ["mcp"] && $0.path != ["agent-guide"] }
        self.version = version; self.guide = agentGuide; self.runner = runner
    }

    public static func toolName(_ path: [String]) -> String {
        path.joined(separator: "_").replacingOccurrences(of: "-", with: "_")
    }

    // MARK: Tools

    private func hasYes(_ c: Command) -> Bool { c.options.contains { $0.name == "yes" } }
    private func needsConfirm(_ c: Command) -> Bool { c.touchesWindows || hasYes(c) }

    func inputSchema(_ c: Command) -> JSONValue {
        var props: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for a in c.args {
            let d = a.summary.isEmpty ? a.name : a.summary
            props[a.name] = a.variadic
                ? .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(d)])
                : .object(["type": .string("string"), "description": .string(d)])
            if a.required { required.append(.string(a.name)) }
        }
        for o in c.options where o.name != "yes" && o.name != "json" && o.name != "help" {
            props[o.name] = .object(["type": .string(o.takesValue ? "string" : "boolean"), "description": .string(o.summary)])
        }
        if needsConfirm(c) {
            props["confirm"] = .object(["type": .string("boolean"), "description": .string(
                "Must be true. Set it only after the user explicitly agreed in this conversation to this exact action.")])
            if c.touchesWindows { required.append(.string("confirm")) }
        }
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(props)]
        if !required.isEmpty { schema["required"] = .array(required) }
        return .object(schema)
    }

    func toolDescription(_ c: Command) -> String {
        var s = c.summary
        if c.mutates { s += " (mutates)" }
        if c.touchesWindows { s += " (moves real windows)" }
        return s
    }

    public func toolList() -> [JSONValue] {
        var tools: [JSONValue] = [.object([
            "name": .string("agent_guide"),
            "description": .string("Markdown guide for AI agents operating Windows Manager: safety rules, recipes, exit codes."),
            "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
        ])]
        for c in commands.sorted(by: { $0.name < $1.name }) {
            tools.append(.object([
                "name": .string(Self.toolName(c.path)),
                "description": .string(toolDescription(c)),
                "inputSchema": inputSchema(c),
            ]))
        }
        return tools
    }

    private func textResult(_ text: String, isError: Bool) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(isError)])
    }

    private func scalar(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// Builds the argv for a tool call, or an error text.
    func buildArgs(_ c: Command, _ a: [String: JSONValue]) -> (args: [String]?, error: String?) {
        var confirm = false
        if case .bool(true)? = a["confirm"] { confirm = true }
        if c.touchesWindows && !confirm {
            return (nil, "`\(c.name)` moves or reads real windows. Ask the user for explicit consent first, then call again with confirm: true.")
        }
        var argv = c.path
        for arg in c.args {
            guard let v = a[arg.name], v != .null else {
                if arg.required { return (nil, "Missing required argument `\(arg.name)`.") }
                continue
            }
            if case .array(let items) = v { argv += items.compactMap(scalar) }
            else if let s = scalar(v) { argv.append(s) }
        }
        for o in c.options where o.name != "yes" && o.name != "json" && o.name != "help" {
            guard let v = a[o.name], v != .null else { continue }
            if o.takesValue {
                if let s = scalar(v) { argv += ["--" + o.name, s] }
            } else if case .bool(true) = v { argv.append("--" + o.name) }
        }
        if hasYes(c) && confirm { argv.append("--yes") }
        argv.append("--json")
        return (argv, nil)
    }

    private func call(_ params: [String: JSONValue]) -> JSONValue {
        guard case .string(let name)? = params["name"] else { return textResult("Missing tool name.", isError: true) }
        if name == "agent_guide" { return textResult(guide, isError: false) }
        guard let c = commands.first(where: { Self.toolName($0.path) == name }) else {
            return textResult("Unknown tool `\(name)`.", isError: true)
        }
        var a: [String: JSONValue] = [:]
        if case .object(let o)? = params["arguments"] { a = o }
        let built = buildArgs(c, a)
        guard let argv = built.args else { return textResult(built.error ?? "Invalid arguments.", isError: true) }
        let r = runner(argv)
        var ok = r.exit == 0
        if let d = r.output.data(using: .utf8), let env = try? JSONDecoder().decode(CLIEnvelope.self, from: d), !env.ok { ok = false }
        else if let first = r.output.split(separator: "\n").last, let d = String(first).data(using: .utf8),
                let env = try? JSONDecoder().decode(CLIEnvelope.self, from: d), !env.ok { ok = false }
        let text = r.output.isEmpty ? "(no output, exit \(r.exit))" : r.output
        return textResult(text, isError: !ok)
    }

    // MARK: JSON-RPC

    private func rpcError(_ id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .int(code), "message": .string(message)])])
    }

    /// Handles one JSON-RPC line. Returns the reply line, or nil for notifications.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8), let msg = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let o) = msg else {
            return encode(rpcError(.null, -32700, "Parse error"))
        }
        guard let id = o["id"], id != .null else { return nil }   // notification
        guard case .string(let method)? = o["method"] else { return encode(rpcError(id, -32600, "Invalid request")) }
        var params: [String: JSONValue] = [:]
        if case .object(let p)? = o["params"] { params = p }
        let result: JSONValue
        switch method {
        case "initialize":
            var pv = Self.protocolVersion
            if case .string(let requested)? = params["protocolVersion"], requested == pv { pv = requested }
            result = .object([
                "protocolVersion": .string(pv),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("windows-manager"), "version": .string(version)]),
            ])
        case "ping": result = .object([:])
        case "tools/list": result = .object(["tools": .array(toolList())])
        case "tools/call": result = call(params)
        default: return encode(rpcError(id, -32601, "Method not found: \(method)"))
        }
        return encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func encode(_ v: JSONValue) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(v), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Reads stdin lines until EOF, writing replies to stdout. Logs go to stderr.
    public func serve() {
        while let line = readLine(strippingNewline: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if let reply = handle(line: t) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }
}
