import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Pure argument helpers of `wm profile` (ProfileArgs). No files, no services.
@Suite struct CLIProfileCommandsTests {
    @Test func parsesFrame() throws {
        let r = try ProfileArgs.parseRect("100, 80,900,600")
        #expect(r == CGRect(x: 100, y: 80, width: 900, height: 600))
    }

    @Test func parsesFractionalFrame() throws {
        let r = try ProfileArgs.parseRect("0.5,0,0.5,1")
        #expect(r == CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
    }

    @Test func rejectsBadFrames() {
        #expect(throws: CLIFailure.self) { try ProfileArgs.parseRect("1,2,3") }
        #expect(throws: CLIFailure.self) { try ProfileArgs.parseRect("a,b,c,d") }
        #expect(throws: CLIFailure.self) { try ProfileArgs.parseRect("0,0,0,600") }
        #expect(throws: CLIFailure.self) { try ProfileArgs.parseRect("0,0,-5,600") }
    }

    @Test func parsesKeyValueOnFirstEquals() throws {
        let kv = try ProfileArgs.parseKeyValue("otherApps=a=b")
        #expect(kv.key == "otherApps")
        #expect(kv.value == "a=b")
        #expect(throws: CLIFailure.self) { try ProfileArgs.parseKeyValue("novalue") }
        #expect(throws: CLIFailure.self) { try ProfileArgs.parseKeyValue("=x") }
    }

    @Test func parsesBooleans() throws {
        #expect(try ProfileArgs.parseBool("Yes", name: "k") == true)
        #expect(try ProfileArgs.parseBool("off", name: "k") == false)
        #expect(throws: CLIFailure.self) { try ProfileArgs.parseBool("maybe", name: "k") }
    }

    @Test func optionChangeAppliesAllAssignments() throws {
        var options = ProfileOptions()
        let change = try ProfileArgs.optionChange(["restoreSpaces=false", "otherApps=hide", "addMissingDesktops=yes"])
        change(&options)
        #expect(options.restoreSpaces == false)
        #expect(options.otherApps == .hide)
        #expect(options.addMissingDesktops == true)
    }

    @Test func optionChangeRejectsUnknownKeysBeforeChanging() {
        #expect(throws: CLIFailure.self) { try ProfileArgs.optionChange(["hotkey=ctrl+opt+cmd+1"]) }
        #expect(throws: CLIFailure.self) { try ProfileArgs.optionChange(["otherApps=burn"]) }
        #expect(throws: CLIFailure.self) { try ProfileArgs.optionChange(["restoreSpaces=perhaps"]) }
    }

    @Test func parsesGrid() throws {
        let grid = try ProfileArgs.parseGrid(columns: "12", rows: "6")
        #expect(grid == GridSpec(columns: 12, rows: 6))
        #expect(throws: CLIFailure.self) { try ProfileArgs.parseGrid(columns: "0", rows: "6") }
        #expect(throws: CLIFailure.self) { try ProfileArgs.parseGrid(columns: "12", rows: nil) }
        #expect(throws: CLIFailure.self) { try ProfileArgs.parseGrid(columns: "99", rows: "6") }
    }

    @Test func parsesWindowIDs() throws {
        let id = UUID()
        #expect(try ProfileArgs.parseUUID(id.uuidString) == id)
        #expect(throws: CLIFailure.self) { try ProfileArgs.parseUUID("not-a-window") }
    }

    @Test func parsesShortcutCombos() throws {
        let combo = try ProfileService.parseShortcut("ctrl+opt+cmd+1")
        #expect(ProfileService.formatShortcut(combo) == "ctrl+opt+cmd+1")
        #expect(throws: ServiceError.self) { try ProfileService.parseShortcut("1") }
        #expect(throws: ServiceError.self) { try ProfileService.parseShortcut("cmd+x") }
    }
}
