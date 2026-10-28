import Foundation

public enum CLIVia: String, Sendable { case app, direct, auto }

/// Error a handler throws; mapped to an error envelope plus exit code.
public struct CLIFailure: Error {
    public var exit: CLIExitCode
    public var code: String
    public var message: String
    public var hint: String?
    public init(_ exit: CLIExitCode, code: String, message: String, hint: String? = nil) {
        self.exit = exit; self.code = code; self.message = message; self.hint = hint
    }
    public static func usage(_ message: String, hint: String? = nil) -> CLIFailure {
        .init(.usage, code: "usage", message: message, hint: hint)
    }
    public static func notFound(_ message: String, hint: String? = nil) -> CLIFailure {
        .init(.notFound, code: "not_found", message: message, hint: hint)
    }
}

public struct CLIResult {
    public var data: JSONValue
    public var exit: CLIExitCode
    /// Plain-text rendering used when `--json` is absent. Falls back to pretty JSON.
    public var text: String?
    public init(data: JSONValue = .null, exit: CLIExitCode = .ok, text: String? = nil) {
        self.data = data; self.exit = exit; self.text = text
    }
}

public struct CLIArg {
    public var name: String
    public var summary: String
    public var required: Bool
    public var variadic: Bool
    public init(_ name: String, _ summary: String = "", required: Bool = true, variadic: Bool = false) {
        self.name = name; self.summary = summary; self.required = required; self.variadic = variadic
    }
}

public struct CLIOption {
    public var name: String          // long name without dashes
    public var short: Character?
    public var summary: String
    public var takesValue: Bool
    public var valueName: String
    public init(_ name: String, short: Character? = nil, _ summary: String = "", takesValue: Bool = false, valueName: String = "value") {
        self.name = name; self.short = short; self.summary = summary; self.takesValue = takesValue; self.valueName = valueName
    }
}

public struct CLIContext {
    public var json: Bool
    public var via: CLIVia
    public var events: NDJSONEventWriter
    public init(json: Bool = false, via: CLIVia = .auto, events: NDJSONEventWriter = NDJSONEventWriter()) {
        self.json = json; self.via = via; self.events = events
    }
}

public struct ParsedArgs {
    public var positionals: [String] = []
    public var options: [String: [String]] = [:]
    public var flags: Set<String> = []
    public init() {}
    public func flag(_ n: String) -> Bool { flags.contains(n) }
    public func value(_ n: String) -> String? { options[n]?.last }
    public func values(_ n: String) -> [String] { options[n] ?? [] }
}

public struct Command {
    /// Full path, e.g. ["profile", "list"].
    public var path: [String]
    public var summary: String
    public var args: [CLIArg]
    public var options: [CLIOption]
    /// True when the command can change stored state (profiles, settings, rules, layouts) or the desktop.
    public var mutates: Bool
    /// True when the command reads or moves real windows (run, capture, verify).
    public var touchesWindows: Bool
    public var handler: (ParsedArgs, CLIContext) throws -> CLIResult

    public init(_ path: [String], summary: String, args: [CLIArg] = [], options: [CLIOption] = [],
                mutates: Bool = false, touchesWindows: Bool = false,
                handler: @escaping (ParsedArgs, CLIContext) throws -> CLIResult) {
        self.path = path; self.summary = summary; self.args = args; self.options = options
        self.mutates = mutates; self.touchesWindows = touchesWindows; self.handler = handler
    }
    public var name: String { path.joined(separator: " ") }

    public var descriptor: JSONValue {
        .object([
            "name": .string(name),
            "path": .array(path.map { .string($0) }),
            "mutates": .bool(mutates),
            "touchesWindows": .bool(touchesWindows),
            "summary": .string(summary),
            "args": .array(args.map { .object(["name": .string($0.name), "summary": .string($0.summary),
                                               "required": .bool($0.required), "variadic": .bool($0.variadic)]) }),
            "options": .array(options.map { .object(["name": .string("--" + $0.name),
                                                     "short": $0.short.map { .string("-\($0)") } ?? .null,
                                                     "summary": .string($0.summary),
                                                     "takesValue": .bool($0.takesValue)]) }),
        ])
    }
}

public enum CLIParseOutcome {
    case run(Command, ParsedArgs, CLIContext)
    case help(String)
    case failure(CLIFailure)
}

public final class Registry {
    public private(set) var commands: [Command] = []
    public init() {}

    public func register(_ c: Command) { commands.removeAll { $0.path == c.path }; commands.append(c) }

    public static let globalOptions: [CLIOption] = [
        CLIOption("json", "Print the JSON envelope"),
        CLIOption("help", short: "h", "Show help"),
        CLIOption("via", "app | direct | auto (default auto)", takesValue: true, valueName: "mode"),
    ]

    /// Longest registered command path that prefixes `tokens`.
    private func match(_ tokens: [String]) -> (Command, Int)? {
        var best: (Command, Int)?
        for c in commands where tokens.count >= c.path.count && Array(tokens.prefix(c.path.count)) == c.path {
            if best == nil || c.path.count > best!.1 { best = (c, c.path.count) }
        }
        return best
    }

    public func parse(_ argv: [String]) -> CLIParseOutcome {
        // Pre-scan global flags so they work anywhere.
        var rest: [String] = []
        var json = false, help = false
        var via = CLIVia.auto
        var i = 0
        var afterDashes = false
        while i < argv.count {
            let a = argv[i]
            if afterDashes { rest.append(a) }
            else if a == "--" { afterDashes = true; rest.append(a) }
            else if a == "--json" { json = true }
            else if a == "--help" || a == "-h" { help = true }
            else if a == "--via" || a.hasPrefix("--via=") {
                let v: String?
                if a.hasPrefix("--via=") { v = String(a.dropFirst(6)) }
                else { i += 1; v = i < argv.count ? argv[i] : nil }
                guard let v, let m = CLIVia(rawValue: v) else {
                    return .failure(.usage("--via must be app, direct or auto"))
                }
                via = m
            } else { rest.append(a) }
            i += 1
        }
        let ctx = CLIContext(json: json, via: via)
        let words = rest.prefix { !$0.hasPrefix("-") }.map { $0 }
        guard let (cmd, used) = match(words) else {
            if help || words.isEmpty { return .help(helpText(prefix: words)) }
            let known = Set(commands.compactMap { $0.path.first })
            if known.contains(words[0]) {
                return .failure(.usage("Unknown subcommand '\(words.joined(separator: " "))'", hint: "Run: wm \(words[0]) --help"))
            }
            return .failure(.usage("Unknown command '\(words[0])'", hint: "Run: wm --help"))
        }
        if help { return .help(helpText(for: cmd)) }

        var p = ParsedArgs()
        var tokens = Array(rest)
        // Remove the command words (they are the first `used` non-dash tokens, all at the start of non-option tokens).
        var removed = 0
        var idx = 0
        while idx < tokens.count && removed < used {
            if tokens[idx] == cmd.path[removed] { tokens.remove(at: idx); removed += 1 } else { idx += 1 }
        }
        var j = 0
        var literal = false
        while j < tokens.count {
            let t = tokens[j]
            if literal || !t.hasPrefix("-") || t == "-" { p.positionals.append(t) }
            else if t == "--" { literal = true }
            else {
                var name: String, inline: String? = nil
                var opt: CLIOption?
                if t.hasPrefix("--") {
                    let body = String(t.dropFirst(2))
                    if let eq = body.firstIndex(of: "=") { name = String(body[..<eq]); inline = String(body[body.index(after: eq)...]) }
                    else { name = body }
                    opt = cmd.options.first { $0.name == name }
                } else {
                    name = String(t.dropFirst())
                    opt = name.count == 1 ? cmd.options.first { $0.short == name.first } : nil
                }
                guard let o = opt else { return .failure(.usage("Unknown option '\(t)'", hint: "Run: wm \(cmd.name) --help")) }
                if o.takesValue {
                    if let inline { p.options[o.name, default: []].append(inline) }
                    else if j + 1 < tokens.count { j += 1; p.options[o.name, default: []].append(tokens[j]) }
                    else { return .failure(.usage("Option --\(o.name) needs a value")) }
                } else { p.flags.insert(o.name) }
            }
            j += 1
        }
        let required = cmd.args.filter { $0.required }.count
        if p.positionals.count < required {
            let missing = cmd.args.filter { $0.required }[p.positionals.count].name
            return .failure(.usage("Missing argument <\(missing)>", hint: "Run: wm \(cmd.name) --help"))
        }
        if !(cmd.args.last?.variadic ?? false), p.positionals.count > cmd.args.count {
            return .failure(.usage("Unexpected argument '\(p.positionals[cmd.args.count])'", hint: "Run: wm \(cmd.name) --help"))
        }
        return .run(cmd, p, ctx)
    }

    public func helpText(prefix: [String] = []) -> String {
        let subset = commands.filter { Array($0.path.prefix(prefix.count)) == prefix }
        var out = prefix.isEmpty ? "wm - Windows Manager CLI\n\nUsage: wm <command> [options]\n\nCommands:\n"
                                 : "Usage: wm \(prefix.joined(separator: " ")) <subcommand> [options]\n\nCommands:\n"
        for c in subset.sorted(by: { $0.name < $1.name }) {
            out += "  " + c.name.padding(toLength: 24, withPad: " ", startingAt: 0) + c.summary + "\n"
        }
        out += "\nGlobal options:\n" + Self.optionLines(Self.globalOptions)
        return out
    }

    public func helpText(for c: Command) -> String {
        var out = "wm \(c.name) - \(c.summary)\n\nUsage: wm \(c.name)"
        for a in c.args { out += a.required ? " <\(a.name)\(a.variadic ? "..." : "")>" : " [\(a.name)\(a.variadic ? "..." : "")]" }
        out += " [options]\n"
        if !c.args.isEmpty { out += "\nArguments:\n" + c.args.map { "  " + $0.name.padding(toLength: 24, withPad: " ", startingAt: 0) + $0.summary }.joined(separator: "\n") + "\n" }
        out += "\nOptions:\n" + Self.optionLines(c.options + Self.globalOptions)
        return out
    }

    private static func optionLines(_ opts: [CLIOption]) -> String {
        opts.map { o in
            var l = "--" + o.name + (o.takesValue ? " <\(o.valueName)>" : "")
            if let s = o.short { l = "-\(s), " + l }
            return "  " + l.padding(toLength: 24, withPad: " ", startingAt: 0) + o.summary
        }.joined(separator: "\n") + "\n"
    }

    /// Runs parse + handler and returns (stdout text, exit code). Pure so it is testable.
    public func execute(_ argv: [String]) -> (output: String, exit: CLIExitCode) {
        let wantsJSON = argv.contains("--json")
        switch parse(argv) {
        case .help(let t): return (t, .ok)
        case .failure(let f): return (render(.failure(code: f.code, message: f.message, hint: f.hint), json: wantsJSON, text: nil), f.exit)
        case .run(let cmd, let args, let ctx):
            do {
                let r = try cmd.handler(args, ctx)
                return (render(.success(r.data), json: ctx.json, text: r.text), r.exit)
            } catch let f as CLIFailure {
                return (render(.failure(code: f.code, message: f.message, hint: f.hint), json: ctx.json, text: nil), f.exit)
            } catch {
                return (render(.failure(code: "runtime", message: "\(error)"), json: ctx.json, text: nil), .runtime)
            }
        }
    }

    private func render(_ env: CLIEnvelope, json: Bool, text: String?) -> String {
        if json { return env.jsonString() }
        if env.ok { return text ?? env.jsonString(pretty: true) }
        var s = "error: \(env.error!.message)"
        if let h = env.error!.hint { s += "\nhint: \(h)" }
        return s
    }
}
