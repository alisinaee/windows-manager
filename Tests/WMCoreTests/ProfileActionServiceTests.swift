import Foundation
import Testing
@testable import WMCore

/// `wm profile action` (P9.4): steps JSON validation and the action edits on a temporary profile store.
@Suite struct ProfileActionServiceTests {
    private func makeService() throws -> (ProfileService, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-profile-actions-\(UUID().uuidString)", isDirectory: true)
        return (ProfileService(store: ProfileStore(folder: folder)), folder)
    }

    private func sampleSteps() -> [ActionStep] {
        let connect = ElementLocator(bundleID: "com.effect.streisand", path: [ElementMatcher(role: "AXButton", title: "Connect")])
        let status = ElementLocator(bundleID: "com.effect.streisand", path: [ElementMatcher(role: "AXStaticText", title: "Connected")])
        return [
            .launchApp(bundleID: "com.effect.streisand"),
            .press(locator: connect),
            .waitFor(locator: status, containing: "Connected", timeout: 15),
            .shell(command: "echo ok"),
        ]
    }

    private func encode(_ steps: [ActionStep]) throws -> Data {
        try JSONEncoder().encode(steps)
    }

    /// The example from the agent guide (section 4.5). It must stay decodable.
    private let guideExample = """
    [
      {"launchApp": {"bundleID": "com.effect.streisand"}},
      {"menu": {"bundleID": "com.effect.streisand", "path": ["File", "New Window"]}},
      {"waitFor": {"locator": {"bundleID": "com.effect.streisand", "path": [{"role": "AXButton", "description": "Connected"}]}, "timeout": 15}}
    ]
    """

    @Test func stepsRoundTripThroughTheCodableForm() throws {
        let steps = sampleSteps()
        let data = try encode(steps)
        #expect(try ProfileService.decodeSteps(data) == steps)
    }

    @Test func guideExampleDecodes() throws {
        let steps = try ProfileService.decodeSteps(Data(guideExample.utf8))
        #expect(steps.count == 3)
        #expect(steps[0] == .launchApp(bundleID: "com.effect.streisand"))
        #expect(steps[1] == .menu(bundleID: "com.effect.streisand", path: ["File", "New Window"]))
        if case .waitFor(let locator, _, let timeout) = steps[2] {
            #expect(locator.path.first?.description == "Connected")
            #expect(timeout == 15)
        } else {
            Issue.record("step 3 should be a waitFor")
        }
        #expect(steps[2].summary == "wait for com.effect.streisand / Connected")
    }

    @Test func rejectsStepsThatDoNotDecode() {
        #expect(throws: ServiceError.self) { try ProfileService.decodeSteps(Data(#"[{"nope":{}}]"#.utf8)) }
        #expect(throws: ServiceError.self) { try ProfileService.decodeSteps(Data(#"{"launchApp":{}}"#.utf8)) }
        #expect(throws: ServiceError.self) { try ProfileService.decodeSteps(Data("not json".utf8)) }
    }

    @Test func rejectsStepsThatDecodeButMakeNoSense() throws {
        let badKey = try encode([.key(combo: "cmd+zzz")])
        #expect(throws: ServiceError.self) { try ProfileService.decodeSteps(badKey) }
        let emptyCommand = try encode([.shell(command: "   ")])
        #expect(throws: ServiceError.self) { try ProfileService.decodeSteps(emptyCommand) }
        let negativeDelay = try encode([.delay(seconds: -1)])
        #expect(throws: ServiceError.self) { try ProfileService.decodeSteps(negativeDelay) }
        let noPath = try encode([.press(locator: ElementLocator(bundleID: "a.b", path: []))])
        #expect(throws: ServiceError.self) { try ProfileService.decodeSteps(noPath) }
        #expect(try ProfileService.decodeSteps(try encode([.key(combo: "cmd+shift+t")])) == [.key(combo: "cmd+shift+t")])
    }

    @Test func parsesPhases() throws {
        #expect(try ProfileService.parsePhase("before") == .beforeRestore)
        #expect(try ProfileService.parsePhase("After") == .afterRestore)
        #expect(try ProfileService.parsePhase("afterRestore") == .afterRestore)
        #expect(throws: ServiceError.self) { try ProfileService.parsePhase("during") }
    }

    @Test func addListShowDeleteOnTempStore() throws {
        let (service, folder) = try makeService()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try service.createBlank(name: "Work")

        let connect = try service.addAction("Work", name: "Connect VPN", phase: .beforeRestore, steps: sampleSteps())
        let tidy = try service.addAction("work", name: "Tidy", phase: .afterRestore)

        let list = try service.actions("Work")
        #expect(list.map(\.name) == ["Connect VPN", "Tidy"])
        #expect(list[0].phase == .beforeRestore)
        #expect(list[0].steps == sampleSteps())
        #expect(list[1].steps.isEmpty)

        // Stored on disk: a fresh service on the same folder sees them.
        let reopened = ProfileService(store: ProfileStore(folder: folder))
        #expect(try reopened.action("Work", action: "connect vpn") == connect)
        #expect(try reopened.action("Work", action: connect.id.uuidString) == connect)
        #expect(try reopened.action("Work", action: tidy.id.uuidString).name == "Tidy")

        let removed = try service.deleteAction("Work", action: "Connect VPN")
        #expect(removed.id == connect.id)
        #expect(try service.actions("Work").map(\.name) == ["Tidy"])
    }

    @Test func editsStepsNameEnabledAndOrder() throws {
        let (service, folder) = try makeService()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try service.createBlank(name: "Work")
        _ = try service.addAction("Work", name: "A", phase: .afterRestore)
        _ = try service.addAction("Work", name: "B", phase: .beforeRestore)
        _ = try service.addAction("Work", name: "C", phase: .afterRestore)

        try service.moveAction("Work", action: "C", toPosition: 1)
        #expect(try service.actions("Work").map(\.name) == ["C", "A", "B"])
        #expect(throws: ServiceError.self) { try service.moveAction("Work", action: "C", toPosition: 4) }
        #expect(throws: ServiceError.self) { try service.moveAction("Work", action: "C", toPosition: 0) }

        try service.setActionSteps("Work", action: "A", steps: [.delay(seconds: 2)])
        #expect(try service.action("Work", action: "A").steps == [.delay(seconds: 2)])

        let renamed = try service.renameAction("Work", action: "B", to: "Bee")
        #expect(renamed.name == "Bee")
        #expect(throws: ServiceError.self) { try service.renameAction("Work", action: "Bee", to: "a") }

        try service.setActionEnabled("Work", action: "Bee", enabled: false)
        #expect(try service.action("Work", action: "Bee").enabled == false)
        try service.setActionEnabled("Work", action: "Bee", enabled: true)
        #expect(try service.action("Work", action: "Bee").enabled == true)
    }

    @Test func refsAndNamesAreChecked() throws {
        let (service, folder) = try makeService()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try service.createBlank(name: "Work")
        _ = try service.addAction("Work", name: "Dup", phase: .afterRestore)

        #expect(throws: ServiceError.self) { try service.addAction("Work", name: "dup", phase: .beforeRestore) }
        #expect(throws: ServiceError.self) { try service.addAction("Work", name: "   ", phase: .beforeRestore) }
        #expect(throws: ServiceError.self) { try service.action("Work", action: "Missing") }
        #expect(throws: ServiceError.self) { try service.deleteAction("Work", action: UUID().uuidString) }
        #expect(throws: ServiceError.self) { try service.addAction("Work", name: "Bad", phase: .afterRestore, steps: [.key(combo: "nope+")]) }
        #expect(try service.actions("Work").map(\.name) == ["Dup"])
    }
}
