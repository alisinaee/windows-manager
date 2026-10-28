import Foundation
import Testing
@testable import WMCore

@Suite struct IPCTests {
    @Test func requestRoundTrip() throws {
        let r = IPCRequest(id: "1", command: "run", args: ["profile": .string("Work")])
        let d = try IPCCodec.encode(r)
        #expect(d.last == 0x0A)
        #expect(try IPCCodec.decodeRequest(d.dropLast()) == r)
    }

    @Test func missingArgsDefaultsEmpty() throws {
        let r = try IPCCodec.decodeRequest(Data(#"{"id":"a","command":"status"}"#.utf8))
        #expect(r.args.isEmpty)
    }

    @Test func badRequestThrows() {
        #expect(throws: IPCError.self) { try IPCCodec.decodeRequest(Data("nope".utf8)) }
    }

    @Test func responseRoundTrip() throws {
        let ok = IPCResponse.success(id: "1", .object(["n": .int(3)]))
        #expect(try IPCCodec.decodeResponse(try IPCCodec.encode(ok).dropLast()) == ok)
        let bad = IPCResponse.failure(id: "2", code: "not_found", message: "x", hint: "h")
        #expect(try IPCCodec.decodeResponse(try IPCCodec.encode(bad).dropLast()) == bad)
    }

    @Test func lineBufferSplitsLines() {
        var b = IPCLineBuffer()
        b.append(Data("ab".utf8)); #expect(b.nextLine() == nil)
        b.append(Data("c\nde\nf".utf8))
        #expect(b.nextLine() == Data("abc".utf8))
        #expect(b.nextLine() == Data("de".utf8))
        #expect(b.nextLine() == nil)
    }

    private func tempSocket() -> String { "/tmp/wmipc-\(UUID().uuidString.prefix(8)).sock" }

    @Test func loopbackServerAndClient() throws {
        let path = tempSocket()
        let server = IPCServer(socketPath: path) { req in
            req.command == "echo" ? .success(id: req.id, .object(req.args))
                                  : .failure(id: req.id, code: "unknown_command", message: req.command)
        }
        try server.start()
        defer { server.stop() }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        let client = IPCClient(socketPath: path, timeout: 3)
        let r = try client.send("echo", args: ["a": .string("b")])
        #expect(r.ok && r.data == .object(["a": .string("b")]))
        let bad = try client.send("zzz")
        #expect(!bad.ok && bad.error?.code == "unknown_command")
    }

    @Test func notRunningWhenNoSocket() {
        let client = IPCClient(socketPath: tempSocket(), timeout: 1)
        #expect(throws: IPCError.notRunning) { try client.send("status") }
    }

    @Test func clientTimesOutOnSilentServer() throws {
        let path = tempSocket()
        let server = IPCServer(socketPath: path) { req in
            Thread.sleep(forTimeInterval: 1.5)
            return .success(id: req.id)
        }
        try server.start()
        defer { server.stop() }
        #expect(throws: IPCError.timeout) { try IPCClient(socketPath: path, timeout: 0.3).send("status") }
    }
}
