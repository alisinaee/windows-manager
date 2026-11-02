import Foundation
import Testing
@testable import WMCore

private final class FakeNode: AXNode, @unchecked Sendable {
    var role: String?
    var subrole: String?
    var title: String?
    var identifier: String?
    var descriptionText: String?
    var value: String?
    var kids: [FakeNode]
    var pressResult = true
    var pressCount = 0
    var focusCount = 0
    init(_ role: String, title: String? = nil, id: String? = nil, desc: String? = nil, value: String? = nil,
         subrole: String? = nil, _ kids: [FakeNode] = []) {
        self.role = role; self.title = title; self.identifier = id; self.descriptionText = desc
        self.value = value; self.subrole = subrole; self.kids = kids
    }
    func children() -> [any AXNode] { kids }
    func press() -> Bool { pressCount += 1; return pressResult }
    func focus() -> Bool { focusCount += 1; return true }
}

private final class FakeAX: AXProvider, @unchecked Sendable {
    var roots: [FakeNode] = []
    var menu: FakeNode?
    var keys: [KeyCombo] = []
    var typed: [String] = []
    /// Called on every roots() query, lets a test grow the tree over time.
    var onQuery: (() -> Void)?
    func roots(bundleID: String) -> [any AXNode] { onQuery?(); return roots }
    func menuBar(bundleID: String) -> (any AXNode)? { menu }
    func sendKey(_ combo: KeyCombo) throws { keys.append(combo) }
    func typeText(_ text: String) throws { typed.append(text) }
}

private final class FakeProcess: ProcessRunner, @unchecked Sendable {
    var log: [String] = []
    var shellExit: Int32 = 0
    func runShell(_ c: String, waitForExit: Bool, timeout: TimeInterval) async throws -> ShellResult {
        log.append("shell:\(c):\(waitForExit):\(timeout)")
        return ShellResult(exitCode: shellExit, output: "boom")
    }
    func runShortcut(_ n: String, timeout: TimeInterval) async throws -> ShellResult { log.append("shortcut:\(n)"); return ShellResult(exitCode: 0) }
    func launchApp(bundleID: String, timeout: TimeInterval) async throws { log.append("launch:\(bundleID)") }
    func openURL(_ url: String) async throws { log.append("url:\(url)") }
}

private final class FakeClock: ActionClock, @unchecked Sendable {
    var t: TimeInterval = 0
    var onSleep: (() -> Void)?
    func now() -> TimeInterval { t }
    func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        t += seconds
        onSleep?()
    }
}

private final class ActionTaskBox: @unchecked Sendable { var task: Task<ActionRunReport, Never>? }

private func loc(_ matchers: ElementMatcher...) -> ElementLocator { ElementLocator(bundleID: "app.x", path: matchers) }
private func button(_ title: String) -> ElementMatcher { ElementMatcher(role: "AXButton", title: title) }

@Suite struct ActionStepTests {
    private func runner(_ ax: FakeAX, _ p: FakeProcess = FakeProcess(), _ c: FakeClock = FakeClock()) -> ActionRunner {
        ActionRunner(ax: ax, process: p, clock: c)
    }

    @Test func codableRoundTrip() throws {
        let l = loc(ElementMatcher(role: "AXWindow"), ElementMatcher(role: "AXButton", subrole: "s", title: "Connect",
                                                                     identifier: "id", description: "d", index: 2))
        let action = ProfileAction(name: "VPN", phase: .beforeRestore, steps: [
            .launchApp(bundleID: "a.b"), .press(l, timeout: 3), .menu(bundleID: "a.b", path: ["File", "New Window"]),
            .typeText("hi", into: l), .typeText("x"), .key("cmd+t"), .shell(command: "ls", waitForExit: false, timeout: 9),
            .openURL("https://a.b"), .runShortcut(name: "S"), .waitFor(l, containing: "On", timeout: 4),
            .delay(seconds: 1.5), .optional(.key("esc")),
        ], enabled: false)
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(ProfileAction.self, from: data) == action)
    }

    @Test func defaults() {
        #expect(ActionStep.press(loc(button("a"))).timeout == ActionDefaults.uiTimeout)
        #expect(ActionStep.shell(command: "x").timeout == ActionDefaults.shellTimeout)
        #expect(!ActionStep.key("a").continueOnFailure)
        #expect(ActionStep.optional(.key("a")).continueOnFailure)
    }

    @Test func keyComboParsing() {
        #expect(KeyCombo.parse("cmd+shift+t") == KeyCombo(modifiers: [.command, .shift], keyCode: 17))
        #expect(KeyCombo.parse("Return")?.keyCode == 36)
        #expect(KeyCombo.parse("hyper+t") == nil)
        #expect(KeyCombo.parse("cmd+") == nil)
    }

    @Test func matcherPriority() {
        let m = ElementMatcher(role: "AXButton", title: "Connect", identifier: "go")
        #expect(m.rank(role: "AXButton", subrole: nil, title: "x", identifier: "go", description: nil) == 3)
        #expect(m.rank(role: "AXButton", subrole: nil, title: "Connect", identifier: nil, description: nil) == 2)
        #expect(m.rank(role: "AXButton", subrole: nil, title: "Tap to CONNECT now", identifier: nil, description: nil) == 1)
        #expect(m.rank(role: "AXButton", subrole: nil, title: "Other", identifier: nil, description: nil) == nil)
        #expect(m.rank(role: "AXLink", subrole: nil, title: "Connect", identifier: nil, description: nil) == nil)
    }

    @Test func searchPrefersBestRankAndIndex() {
        let contains = FakeNode("AXButton", title: "Connect to server")
        let exact = FakeNode("AXButton", title: "Connect")
        let exact2 = FakeNode("AXButton", title: "Connect")
        let root = FakeNode("AXWindow", [contains, FakeNode("AXGroup", [exact]), exact2])
        #expect(ElementSearch.find(loc(button("Connect")), roots: [root]) === exact2)
        var m = button("Connect"); m.index = 1
        #expect(ElementSearch.find(loc(m), roots: [root]) === exact)
        m.index = 5
        #expect(ElementSearch.find(loc(m), roots: [root]) == nil)
        #expect(ElementSearch.find(loc(button("conn")), roots: [root]) === contains)
    }

    @Test func searchNestedPathAndLimits() {
        let target = FakeNode("AXButton", id: "ok")
        let sheet = FakeNode("AXSheet", [FakeNode("AXGroup", [target])])
        let other = FakeNode("AXButton", id: "ok")
        let root = FakeNode("AXWindow", [FakeNode("AXGroup", [other]), sheet])
        let l = loc(ElementMatcher(role: "AXSheet"), ElementMatcher(role: "AXButton", identifier: "ok"))
        #expect(ElementSearch.find(l, roots: [root]) === target)
        #expect(ElementSearch.find(l, roots: [root], maxDepth: 1) == nil)
        #expect(ElementSearch.find(l, roots: [root], maxNodes: 2) == nil)
    }

    @Test func menuPath() {
        let item = FakeNode("AXMenuItem", title: "New Window")
        let bar = FakeNode("AXMenuBar", [
            FakeNode("AXMenuBarItem", title: "Edit", [FakeNode("AXMenu", [FakeNode("AXMenuItem", title: "Copy")])]),
            FakeNode("AXMenuBarItem", title: "File", [FakeNode("AXMenu", [FakeNode("AXMenuItem", title: "Open"), item])]),
        ])
        #expect(ElementSearch.menuItem(path: ["File", "New Window"], in: bar) === item)
        #expect(ElementSearch.menuItem(path: ["File", "Nope"], in: bar) == nil)
    }

    @Test func runsStepsInOrderAndReports() async {
        let ax = FakeAX()
        let btn = FakeNode("AXButton", title: "Connect")
        ax.roots = [FakeNode("AXWindow", [btn])]
        let p = FakeProcess()
        let action = ProfileAction(name: "a", steps: [
            .launchApp(bundleID: "app.x"), .press(loc(button("Connect"))), .key("cmd+t"), .typeText("hello"),
            .shell(command: "echo hi"), .openURL("https://x.y"), .runShortcut(name: "S"), .delay(seconds: 2),
        ])
        let r = await runner(ax, p).run(action)
        #expect(r.succeeded && r.completed)
        #expect(r.steps.map(\.status) == Array(repeating: .succeeded, count: 8))
        #expect(btn.pressCount == 1)
        #expect(ax.keys.count == 1 && ax.typed == ["hello"])
        #expect(p.log == ["launch:app.x", "shell:echo hi:true:60.0", "url:https://x.y", "shortcut:S"])
        #expect(r.steps[7].duration == 2)
    }

    @Test func failureStopsAndSkipsRest() async {
        let ax = FakeAX()
        let action = ProfileAction(name: "a", steps: [
            .delay(seconds: 0), .press(loc(button("Missing")), timeout: 1), .key("cmd+t"),
        ])
        let r = await runner(ax).run(action)
        #expect(r.steps.map(\.status) == [.succeeded, .failed, .skipped])
        #expect(r.steps[1].error?.contains("element not found") == true)
        #expect(ax.keys.isEmpty)
        #expect(!r.succeeded)
    }

    @Test func continueOnFailureKeepsGoing() async {
        let ax = FakeAX()
        let p = FakeProcess(); p.shellExit = 3
        let action = ProfileAction(name: "a", steps: [
            .optional(.shell(command: "false")), .key("cmd+t"), .key("nonsense+"),
        ])
        let r = await runner(ax, p).run(action)
        #expect(r.steps.map(\.status) == [.failed, .succeeded, .failed])
        #expect(r.steps[0].error?.contains("exited with 3") == true)
        #expect(r.steps[2].error?.contains("invalid key") == true)
        #expect(ax.keys.count == 1)
    }

    @Test func timeoutPollsEvery200ms() async {
        let ax = FakeAX()
        let c = FakeClock()
        nonisolated(unsafe) var queries = 0
        ax.onQuery = { queries += 1 }
        let r = await runner(ax, FakeProcess(), c).run(ProfileAction(name: "a", steps: [
            .waitFor(loc(button("Never")), timeout: 1),
        ]))
        #expect(r.steps[0].status == .failed)
        #expect(c.t >= 1 && c.t < 1.3)
        #expect(queries >= 5 && queries <= 7)
    }

    @Test func waitForSucceedsWhenElementAppearsWithText() async {
        let ax = FakeAX()
        let status = FakeNode("AXStaticText", id: "state", value: "Connecting")
        let c = FakeClock()
        ax.roots = [FakeNode("AXWindow", [status])]
        c.onSleep = { if c.t > 0.5 { status.value = "Connected" } }
        let l = loc(ElementMatcher(role: "AXStaticText", identifier: "state"))
        let r = await runner(ax, FakeProcess(), c).run(ProfileAction(name: "a", steps: [
            .waitFor(l, containing: "connected", timeout: 5),
        ]))
        #expect(r.succeeded)
        #expect(c.t < 1.5)

        status.value = "Off"
        let r2 = await runner(ax, FakeProcess(), FakeClock()).run(ProfileAction(name: "a", steps: [
            .waitFor(l, containing: "on!", timeout: 1),
        ]))
        #expect(r2.steps[0].error?.contains("does not match") == true)
    }

    @Test func menuStepAndTypeIntoFocuses() async {
        let ax = FakeAX()
        let item = FakeNode("AXMenuItem", title: "New Window")
        ax.menu = FakeNode("AXMenuBar", [FakeNode("AXMenuBarItem", title: "File", [FakeNode("AXMenu", [item])])])
        let field = FakeNode("AXTextField", id: "f")
        ax.roots = [FakeNode("AXWindow", [field])]
        let r = await runner(ax).run(ProfileAction(name: "a", steps: [
            .menu(bundleID: "app.x", path: ["File", "New Window"]),
            .typeText("abc", into: loc(ElementMatcher(role: "AXTextField", identifier: "f"))),
        ]))
        #expect(r.succeeded)
        #expect(item.pressCount == 1 && field.focusCount == 1 && ax.typed == ["abc"])
    }

    @Test func disabledActionSkipsEverything() async {
        let ax = FakeAX()
        let r = await runner(ax).run(ProfileAction(name: "a", steps: [.key("cmd+t")], enabled: false))
        #expect(r.steps.map(\.status) == [.skipped])
        #expect(ax.keys.isEmpty)
    }

    @Test func cancelledBeforeStart() async {
        let ax = FakeAX()
        let action = ProfileAction(name: "a", steps: [.delay(seconds: 1), .key("cmd+t"), .key("cmd+w")])
        let t = Task { () -> ActionRunReport in
            while !Task.isCancelled { await Task.yield() }
            return await runner(ax).run(action)
        }
        t.cancel()
        let r = await t.value
        #expect(r.cancelled && !r.succeeded)
        #expect(r.steps.allSatisfy { $0.status == .cancelled })
        #expect(ax.keys.isEmpty)
    }

    @Test func cancellationMidStep() async {
        let ax = FakeAX()
        let c = FakeClock()
        let action = ProfileAction(name: "a", steps: [.key("cmd+t"), .delay(seconds: 1), .key("cmd+w")])
        let box = ActionTaskBox()
        c.onSleep = { box.task?.cancel() }
        let task = Task { await runner(ax, FakeProcess(), c).run(action) }
        box.task = task
        let r = await task.value
        #expect(ax.keys.count == 1)
        #expect(r.steps[2].status == .cancelled)
        #expect(r.cancelled)
    }
}
