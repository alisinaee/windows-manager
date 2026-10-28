import Testing
import Foundation
@testable import WMCore

@Suite struct CLISchemaTests {
    private func noop(_ path: [String], mutates: Bool = false, touchesWindows: Bool = false) -> Command {
        Command(path, summary: "s", args: [CLIArg("profile")], options: [CLIOption("yes", "Confirm")],
                mutates: mutates, touchesWindows: touchesWindows) { _, _ in CLIResult() }
    }

    private func object(_ v: JSONValue?) -> [String: JSONValue] {
        if case .object(let o)? = v { return o }
        return [:]
    }

    @Test func descriptorCarriesSafetyFlags() {
        let d = object(noop(["run"], mutates: true, touchesWindows: true).descriptor)
        #expect(d["name"] == .string("run"))
        #expect(d["path"] == .array([.string("run")]))
        #expect(d["mutates"] == .bool(true))
        #expect(d["touchesWindows"] == .bool(true))
    }

    @Test func safetyFlagsDefaultToFalse() {
        let d = object(noop(["plan"]).descriptor)
        #expect(d["mutates"] == .bool(false))
        #expect(d["touchesWindows"] == .bool(false))
    }

    @Test func documentSortsCommandsAndListsExitCodes() {
        let doc = object(CLISchema.document(version: "9.9.9", commands: [noop(["verify"], touchesWindows: true), noop(["plan"])]))
        #expect(doc["version"] == .string("9.9.9"))
        #expect(doc["schemaVersion"] == .int(CLISchema.schemaVersion))
        guard case .array(let cmds)? = doc["commands"] else { Issue.record("commands missing"); return }
        #expect(cmds.compactMap { object($0)["name"] } == [.string("plan"), .string("verify")])
        guard case .array(let codes)? = doc["exitCodes"] else { Issue.record("exitCodes missing"); return }
        #expect(codes.count == 7)
        #expect(object(codes.last)["code"] == .int(6))
        #expect(object(doc["envelope"])["failure"] != nil)
    }

    @Test func documentRoundTripsThroughJSON() throws {
        let doc = CLISchema.document(version: "1", commands: [noop(["profile", "delete"], mutates: true)])
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == doc)
    }
}
