import Testing
import Foundation
@testable import WMCore

@Suite struct MCPServerTests {
    final class Calls { var argv: [[String]] = [] }

    private func server(_ calls: Calls = Calls(), out: String = #"{"ok":true,"data":1}"#, exit: Int32 = 0) -> MCPServer {
        let cmds = [
            Command(["status"], summary: "Show status") { _, _ in CLIResult() },
            Command(["profile", "delete"], summary: "Delete", args: [CLIArg("profile")], options: [CLIOption("yes", "Confirm")], mutates: true) { _, _ in CLIResult() },
            Command(["run"], summary: "Run", args: [CLIArg("profile")], options: [CLIOption("dry-run", "Dry")], touchesWindows: true) { _, _ in CLIResult() },
            Command(["agent-guide"], summary: "g") { _, _ in CLIResult() },
        ]
        return MCPServer(commands: cmds, version: "9", agentGuide: "GUIDE") { a in calls.argv.append(a); return (out, exit) }
    }

    private func obj(_ s: String?) -> [String: JSONValue] {
        guard let s, let d = s.data(using: .utf8), case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: d) else { return [:] }
        return o
    }

    @Test func initializeAndNotifications() {
        let s = server()
        let r = obj(s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        guard case .object(let res)? = r["result"] else { Issue.record("no result"); return }
        #expect(res["protocolVersion"] == .string("2025-06-18"))
        #expect(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(obj(s.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#))["result"] != nil)
        #expect(obj(s.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"nope"}"#))["error"] != nil)
        #expect(obj(s.handle(line: "garbage"))["error"] != nil)
    }

    @Test func toolsListNamesAndSchema() {
        let names = server().toolList().compactMap { t -> String? in
            if case .object(let o) = t, case .string(let n)? = o["name"] { return n } else { return nil }
        }
        #expect(names == ["agent_guide", "profile_delete", "run", "status"])
    }

    @Test func runRequiresConfirm() {
        let calls = Calls(); let s = server(calls)
        let r = obj(s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run","arguments":{"profile":"p"}}}"#))
        guard case .object(let res)? = r["result"] else { Issue.record("no result"); return }
        #expect(res["isError"] == .bool(true))
        #expect(calls.argv.isEmpty)
        _ = s.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"profile":"p","dry-run":true,"confirm":true}}}"#)
        #expect(calls.argv == [["run", "p", "--dry-run", "--json"]])
    }

    @Test func yesOnlyWithConfirm() {
        let calls = Calls(); let s = server(calls)
        _ = s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"profile_delete","arguments":{"profile":"p","yes":true}}}"#)
        _ = s.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"profile_delete","arguments":{"profile":"p","confirm":true}}}"#)
        #expect(calls.argv == [["profile", "delete", "p", "--json"], ["profile", "delete", "p", "--yes", "--json"]])
    }

    @Test func envelopeFailureIsError() {
        let s = server(out: #"{"ok":false,"error":{"code":"x","message":"m"}}"#, exit: 0)
        let r = obj(s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"status","arguments":{}}}"#))
        guard case .object(let res)? = r["result"] else { Issue.record("no result"); return }
        #expect(res["isError"] == .bool(true))
    }

    @Test func agentGuideTool() {
        let r = obj(server().handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"agent_guide"}}"#))
        #expect(String(describing: r).contains("GUIDE"))
    }
}
