import Foundation
import Testing
@testable import WMCore

@Suite struct ControlCommandTests {
    @Test func parsesURLs() throws {
        #expect(try ControlCommand.parse(url: URL(string: "windowsmanager://run?profile=Work%20Day")!) == .run(profile: "Work Day"))
        #expect(try ControlCommand.parse(url: URL(string: "windowsmanager://capture?name=Home")!) == .capture(name: "Home"))
        #expect(try ControlCommand.parse(url: URL(string: "windowsmanager://list")!) == .list)
        #expect(try ControlCommand.parse(url: URL(string: "WindowsManager://LIST")!) == .list)
    }

    @Test func rejectsBadURLs() {
        #expect(throws: ControlCommand.ParseError.wrongScheme) { try ControlCommand.parse(url: URL(string: "https://run?profile=x")!) }
        #expect(throws: ControlCommand.ParseError.missingValue("profile")) { try ControlCommand.parse(url: URL(string: "windowsmanager://run")!) }
        #expect(throws: ControlCommand.ParseError.missingValue("name")) { try ControlCommand.parse(url: URL(string: "windowsmanager://capture?name=%20")!) }
        #expect(throws: ControlCommand.ParseError.unknownCommand("quit")) { try ControlCommand.parse(url: URL(string: "windowsmanager://quit")!) }
    }

    @Test func parsesArguments() throws {
        #expect(try ControlCommand.parse(arguments: ["run", "Work", "Day"]) == .run(profile: "Work Day"))
        #expect(try ControlCommand.parse(arguments: ["capture", "Home"]) == .capture(name: "Home"))
        #expect(try ControlCommand.parse(arguments: ["list"]) == .list)
        #expect(throws: ControlCommand.ParseError.usage) { try ControlCommand.parse(arguments: []) }
        #expect(throws: ControlCommand.ParseError.missingValue("profile")) { try ControlCommand.parse(arguments: ["run"]) }
        #expect(throws: ControlCommand.ParseError.unknownCommand("x")) { try ControlCommand.parse(arguments: ["x"]) }
    }

    @Test func urlRoundTrips() throws {
        for c in [ControlCommand.run(profile: "A & B/ü"), .capture(name: "x y"), .list] {
            #expect(try ControlCommand.parse(url: c.url) == c)
        }
    }
}
