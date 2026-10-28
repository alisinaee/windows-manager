import Testing
import Foundation
@testable import WMCore

@Suite struct CLIOutputTests {
    func makeRegistry() -> Registry {
        let r = Registry()
        r.register(Command(["profile", "show"], summary: "Show", args: [CLIArg("name")],
                           options: [CLIOption("limit", short: "n", takesValue: true)]) { a, _ in
            if a.positionals[0] == "missing" { throw CLIFailure.notFound("no such profile", hint: "wm profile list") }
            return CLIResult(data: .object(["name": .string(a.positionals[0]), "limit": .string(a.value("limit") ?? "")]))
        })
        return r
    }

    @Test func exitCodes() {
        #expect(CLIExitCode.partial.rawValue == 6)
        #expect(CLIExitCode.appNotRunning.rawValue == 5)
        #expect(CLIExitCode.notFound.rawValue == 3)
    }

    @Test func envelopeShapes() {
        #expect(CLIEnvelope.success(.object(["a": .int(1)])).jsonString() == #"{"data":{"a":1},"ok":true}"#)
        let f = CLIEnvelope.failure(code: "x", message: "m", hint: "h").jsonString()
        #expect(f == #"{"error":{"code":"x","hint":"h","message":"m"},"ok":false}"#)
    }

    @Test func parsesOptionsAndGlobals() {
        let r = makeRegistry()
        let out = r.execute(["--json", "profile", "show", "dev", "-n", "3", "--via", "direct"])
        #expect(out.exit == .ok)
        #expect(out.output == #"{"data":{"limit":"3","name":"dev"},"ok":true}"#)
    }

    @Test func errorsMapToExitCodes() {
        let r = makeRegistry()
        #expect(r.execute(["profile", "show", "missing", "--json"]).exit == .notFound)
        #expect(r.execute(["profile", "show"]).exit == .usage)
        #expect(r.execute(["nope"]).exit == .usage)
        #expect(r.execute(["profile", "show", "a", "--bogus"]).exit == .usage)
        #expect(r.execute(["profile", "show", "a", "--via", "x"]).exit == .usage)
        #expect(r.execute(["profile", "--help"]).exit == .ok)
    }

    @Test func ndjsonWriter() {
        var lines: [String] = []
        let w = NDJSONEventWriter { lines.append($0) }
        w.emit("progress", ["step": .int(1)])
        #expect(lines == [#"{"event":"progress","step":1}"#])
    }
}
