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
    var confirmResult = false
    var pickResult = false
    var center: CGPoint?
    var focusable = false
    var order: [String] = []
    func children() -> [any AXNode] { kids }
    func press() -> Bool { pressCount += 1; order.append("press"); return pressResult }
    func focus() -> Bool { focusCount += 1; return true }
    func performAction(_ name: String) -> Bool {
        order.append(name)
        return name == "AXConfirm" ? confirmResult : (name == "AXPick" ? pickResult : false)
    }
    func setFocusedIfSettable() -> Bool { order.append("focus"); return focusable }
    var frameCenter: CGPoint? { center }
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
    var activated: [String] = []
    var clicks: [CGPoint] = []
    var clickFails = false
    func activate(bundleID: String) { activated.append(bundleID) }
    func click(at point: CGPoint) throws {
        if clickFails { throw ActionError.failed("no") }
        clicks.append(point)
    }
}

private final class FakeScripts: ScriptRunner, @unchecked Sendable {
    var sources: [String] = []
    var error: ScriptError?
    func run(_ source: String) async throws {
        sources.append(source)
        if let error { throw error }
    }
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
            .launchApp(bundleID: "a.b"), .press(locator: l, timeout: 3), .menu(bundleID: "a.b", path: ["File", "New Window"]),
            .typeText(text: "hi", into: l), .typeText(text: "x"), .key(combo: "cmd+t"), .shell(command: "ls", waitForExit: false, timeout: 9),
            .openURL(url: "https://a.b"), .runShortcut(name: "S"), .waitFor(locator: l, containing: "On", timeout: 4),
            .delay(seconds: 1.5), .optional(step: .key(combo: "esc")),
        ], enabled: false)
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(ProfileAction.self, from: data) == action)
    }

    @Test func defaults() {
        #expect(ActionStep.press(locator: loc(button("a"))).timeout == ActionDefaults.uiTimeout)
        #expect(ActionStep.shell(command: "x").timeout == ActionDefaults.shellTimeout)
        #expect(!ActionStep.key(combo: "a").continueOnFailure)
        #expect(ActionStep.optional(step: .key(combo: "a")).continueOnFailure)
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
        #expect(ElementSearch.find(loc(m), roots: [root]) == nil) // only one Connect among each parent's children
        m.index = 5
        #expect(ElementSearch.find(loc(m), roots: [root]) == nil)
        #expect(ElementSearch.find(loc(button("conn")), roots: [root]) === contains)
    }

    @Test func indexCountsAmongSiblings() {
        // Subtree-wide counting would make "OK #1" the second button in document order (a1b), not b0 in group B.
        let a0 = FakeNode("AXButton", title: "OK"), a1 = FakeNode("AXButton", title: "OK")
        let b0 = FakeNode("AXButton", title: "OK"), b1 = FakeNode("AXButton", title: "OK")
        let root = FakeNode("AXWindow", [FakeNode("AXGroup", [a0]), FakeNode("AXGroup", [b0, b1]), FakeNode("AXGroup", [a1])])
        var m = button("OK"); m.index = 1
        #expect(ElementSearch.find(loc(m), roots: [root]) === b1)
        m.index = 0
        #expect(ElementSearch.find(loc(m), roots: [root]) === a0)
        m.index = 2
        #expect(ElementSearch.find(loc(m), roots: [root]) == nil)
        // Nested path: the index applies at its own level, below the node the previous matcher chose.
        let sheet = FakeNode("AXSheet", [FakeNode("AXGroup", [FakeNode("AXButton", title: "OK")]), b1])
        m.index = 1
        #expect(ElementSearch.find(loc(ElementMatcher(role: "AXSheet"), m), roots: [FakeNode("AXWindow", [sheet])]) == nil)
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
            .launchApp(bundleID: "app.x"), .press(locator: loc(button("Connect"))), .key(combo: "cmd+t"), .typeText(text: "hello"),
            .shell(command: "echo hi"), .openURL(url: "https://x.y"), .runShortcut(name: "S"), .delay(seconds: 2),
        ], stepGap: 0)
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
            .delay(seconds: 0), .press(locator: loc(button("Missing")), timeout: 1), .key(combo: "cmd+t"),
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
            .optional(step: .shell(command: "false")), .key(combo: "cmd+t"), .key(combo: "nonsense+"),
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
            .waitFor(locator: loc(button("Never")), timeout: 1),
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
            .waitFor(locator: l, containing: "connected", timeout: 5),
        ]))
        #expect(r.succeeded)
        #expect(c.t < 1.5)

        status.value = "Off"
        let r2 = await runner(ax, FakeProcess(), FakeClock()).run(ProfileAction(name: "a", steps: [
            .waitFor(locator: l, containing: "on!", timeout: 1),
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
            .typeText(text: "abc", into: loc(ElementMatcher(role: "AXTextField", identifier: "f"))),
        ]))
        #expect(r.succeeded)
        #expect(item.pressCount == 1 && field.focusCount == 1 && ax.typed == ["abc"])
    }

    @Test func disabledActionSkipsEverything() async {
        let ax = FakeAX()
        let r = await runner(ax).run(ProfileAction(name: "a", steps: [.key(combo: "cmd+t")], enabled: false))
        #expect(r.steps.map(\.status) == [.skipped])
        #expect(ax.keys.isEmpty)
    }

    @Test func cancelledBeforeStart() async {
        let ax = FakeAX()
        let action = ProfileAction(name: "a", steps: [.delay(seconds: 1), .key(combo: "cmd+t"), .key(combo: "cmd+w")])
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
        let action = ProfileAction(name: "a", steps: [.key(combo: "cmd+t"), .delay(seconds: 1), .key(combo: "cmd+w")])
        let box = ActionTaskBox()
        c.onSleep = { box.task?.cancel() }
        let task = Task { await runner(ax, FakeProcess(), c).run(action) }
        box.task = task
        let r = await task.value
        #expect(ax.keys.count == 1)
        #expect(r.steps[2].status == .cancelled)
        #expect(r.cancelled)
    }

    private func vpnWindow(toggleDesc: String, status: String?) -> FakeNode {
        var kids = [FakeNode("AXButton", desc: toggleDesc)]
        if let status { kids.append(FakeNode("AXButton", desc: status)) }
        return FakeNode("AXWindow", title: "Streisand", [FakeNode("AXGroup", kids)])
    }

    @Test func structuralPathFindsButtonWhoseLabelChanged() async {
        let ax = FakeAX()
        ax.roots = [vpnWindow(toggleDesc: "pause.circle.fill", status: "Connected")]
        let locator = ElementLocator(bundleID: "app.x",
                                     path: [ElementMatcher(role: "AXButton", description: "power.circle.fill", volatile: true)],
                                     structural: [StructuralHop(role: "AXGroup", index: 0), StructuralHop(role: "AXButton", index: 0)],
                                     windowIndex: 0, windowTitle: "Streisand")
        #expect(ElementMatcher.looksLikeSymbolName("power.circle.fill"))
        #expect(!ElementMatcher.looksLikeSymbolName("Connected"))
        let report = await runner(ax).run(ProfileAction(name: "t", steps: [.press(locator: locator, timeout: 0)]))
        #expect(report.succeeded)
        let group = ax.roots[0].kids[0]
        #expect(group.kids[0].pressCount == 1)
        // Without structure the same label no longer matches.
        var plain = locator; plain.structural = nil; plain.path[0].volatile = nil
        #expect(ElementSearch.find(plain, roots: ax.roots) == nil)
        // A structural hit with the wrong role is rejected.
        var wrong = locator; wrong.path[0].role = "AXCheckBox"; wrong.path[0].description = "nope"
        #expect(ElementSearch.find(wrong, roots: ax.roots) == nil)
    }

    @Test func positionPreferenceGoesStructuralFirst() {
        let window = vpnWindow(toggleDesc: "power.circle.fill", status: "Connected")
        let group = window.kids[0]
        // Semantic would find the second button; the position says the first.
        let locator = ElementLocator(bundleID: "app.x", path: [ElementMatcher(role: "AXButton", description: "Connected")],
                                     structural: [StructuralHop(role: "AXGroup", index: 0), StructuralHop(role: "AXButton", index: 0)],
                                     match: .position)
        #expect(ElementSearch.find(locator, roots: [window]) === group.kids[0])
        var label = locator; label.match = .label
        #expect(ElementSearch.find(label, roots: [window]) === group.kids[1])
    }

    @Test func skipIfShowingSkipsThePress() async {
        let ax = FakeAX()
        ax.roots = [vpnWindow(toggleDesc: "pause.circle.fill", status: "Connected")]
        let toggle = ElementLocator(bundleID: "app.x", path: [ElementMatcher(role: "AXButton", description: "pause.circle.fill")])
        let showing = ElementLocator(bundleID: "app.x", path: [ElementMatcher(role: "AXButton", description: "Connected")])
        let report = await runner(ax).run(ProfileAction(name: "t", steps: [.press(locator: toggle, timeout: 0, skipIfShowing: showing)]))
        #expect(report.steps[0].status == .skipped)
        #expect(report.steps[0].error == "skipped (already showing)")
        #expect(report.succeeded && report.completed)
        #expect(ax.roots[0].kids[0].kids[0].pressCount == 0)

        ax.roots = [vpnWindow(toggleDesc: "power.circle.fill", status: nil)]
        let toggle2 = ElementLocator(bundleID: "app.x", path: [ElementMatcher(role: "AXButton", description: "power.circle.fill")])
        let again = await runner(ax).run(ProfileAction(name: "t", steps: [.press(locator: toggle2, timeout: 0, skipIfShowing: showing)]))
        #expect(again.steps[0].status == .succeeded)
        #expect(ax.roots[0].kids[0].kids[0].pressCount == 1)
    }

    @Test func oldJSONDecodesWithoutNewKeys() throws {
        let json = #"{"press":{"locator":{"bundleID":"a.b","path":[{"role":"AXButton","title":"Go"}]},"timeout":5}}"#
        let step = try JSONDecoder().decode(ActionStep.self, from: Data(json.utf8))
        guard case .press(let l, _, let skip) = step else { Issue.record("not a press"); return }
        #expect(l.structural == nil && l.windowIndex == nil && l.match == nil && l.path[0].volatile == nil && skip == nil)
        let text = String(decoding: try JSONEncoder().encode(step), as: UTF8.self)
        #expect(!text.contains("structural") && !text.contains("skipIfShowing") && !text.contains("volatile"))
        let full = ActionStep.press(locator: ElementLocator(bundleID: "a.b", path: [ElementMatcher(role: "AXButton", volatile: true)],
                                                           structural: [StructuralHop(role: "AXButton", index: 1)], windowIndex: 0,
                                                           windowTitle: "W", match: .position),
                                    skipIfShowing: ElementLocator(bundleID: "a.b", path: [ElementMatcher(role: "AXStaticText", title: "Connected")]))
        #expect(try JSONDecoder().decode(ActionStep.self, from: try JSONEncoder().encode(full)) == full)
    }

    @Test func legacyUnderscoreKeysStillDecode() throws {
        let element = #""bundleID":"com.effect.streisand","path":[{"role":"AXButton","description":"Connected"}]"#
        let legacy = Data(#"{"press":{"_0":{\#(element)},"timeout":5}}"#.utf8)
        let labeled = Data(#"{"press":{"locator":{\#(element)},"timeout":5}}"#.utf8)
        let expected = ActionStep.press(locator: ElementLocator(bundleID: "com.effect.streisand",
                                                                path: [ElementMatcher(role: "AXButton", description: "Connected")]),
                                        timeout: 5)
        #expect(try JSONDecoder().decode(ActionStep.self, from: legacy) == expected)
        #expect(try JSONDecoder().decode(ActionStep.self, from: labeled) == expected)

        let json = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        #expect(json.contains(#""locator""#))
        #expect(!json.contains("_0"))

        // The other unlabeled values from before P9.6 decode too.
        let text = try JSONDecoder().decode(ActionStep.self, from: Data(#"{"typeText":{"_0":"hi"}}"#.utf8))
        #expect(text == .typeText(text: "hi"))
        let wrapped = try JSONDecoder().decode(ActionStep.self, from: Data(#"{"optional":{"_0":{"key":{"_0":"esc"}}}}"#.utf8))
        #expect(wrapped == .optional(step: .key(combo: "esc")))
    }

    @Test func delaysDecodeFromOldFilesAndRoundTrip() throws {
        let old = Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"a","phase":"afterRestore","steps":[],"enabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ProfileAction.self, from: old)
        #expect(decoded.delayBefore == 0 && decoded.stepGap == 0.3)
        let encodedDefault = try JSONEncoder().encode(decoded)
        #expect(!String(decoding: encodedDefault, as: UTF8.self).contains("stepGap"))
        var custom = decoded
        custom.delayBefore = 2; custom.stepGap = 1
        #expect(try JSONDecoder().decode(ProfileAction.self, from: JSONEncoder().encode(custom)) == custom)
    }

    @Test func runnerWaitsBeforeAndBetweenSteps() async {
        let clock = FakeClock()
        var slept: [TimeInterval] = []
        clock.onSleep = { slept.append(clock.t) }
        var action = ProfileAction(name: "a", steps: [.key(combo: "a"), .key(combo: "b"), .key(combo: "c")],
                                   delayBefore: 2, stepGap: 0.5)
        let r = await runner(FakeAX(), FakeProcess(), clock).run(action)
        #expect(r.succeeded)
        #expect(slept == [2, 2.5, 3])
        action.delayBefore = 0; action.stepGap = 0
        clock.t = 0; slept = []
        _ = await runner(FakeAX(), FakeProcess(), clock).run(action)
        #expect(slept.isEmpty)
    }

    // MARK: P9.12

    @Test func oldTerminalFreeJSONStillDecodes() throws {
        let json = #"{"press":{"locator":{"bundleID":"a","path":[{"role":"AXButton","title":"Go"}]}}}"#
        let step = try JSONDecoder().decode(ActionStep.self, from: Data(json.utf8))
        guard case .press(let l, _, _) = step else { Issue.record("not a press"); return }
        #expect(l.clickMode == nil)
        let cmd = try JSONDecoder().decode(ActionStep.self, from: Data(#"{"terminalCommand":{"command":"ls"}}"#.utf8))
        #expect(cmd == .terminalCommand(command: "ls", app: TerminalApp.terminal, newWindow: false))
        let step2 = ActionStep.terminalCommand(command: "ls", app: TerminalApp.iTerm, newWindow: true)
        #expect(try JSONDecoder().decode(ActionStep.self, from: JSONEncoder().encode(step2)) == step2)
        let click = ActionStep.press(locator: ElementLocator(bundleID: "a", path: [button("x")], clickMode: .pointer))
        #expect(try JSONDecoder().decode(ActionStep.self, from: JSONEncoder().encode(click)) == click)
    }

    @Test func appleScriptEscaping() {
        #expect(TerminalScript.escape(#"echo "a\b""#) == #"echo \"a\\b\""#)
        #expect(TerminalScript.escape("a\nb") == "a\\nb")
        let src = TerminalScript.source(command: #"say "hi""#, app: TerminalApp.terminal, newWindow: false)
        #expect(src?.contains(#"do script "say \"hi\"" in front window"#) == true)
        let fresh = TerminalScript.source(command: "ls", app: TerminalApp.terminal, newWindow: true)
        #expect(fresh?.contains("in front window") == false)
        let iterm = TerminalScript.source(command: "ls", app: TerminalApp.iTerm, newWindow: false)
        #expect(iterm?.contains(#"write text "ls""#) == true)
        #expect(TerminalScript.source(command: "ls", app: "x.y", newWindow: false) == nil)
    }

    @Test func terminalCommandRunsThroughScriptRunner() async {
        let scripts = FakeScripts()
        let r = ActionRunner(ax: FakeAX(), process: FakeProcess(), clock: FakeClock(), scripts: scripts)
        let report = await r.run(ProfileAction(name: "t", steps: [.terminalCommand(command: "fortiChromeMain")]))
        #expect(report.succeeded)
        #expect(scripts.sources.count == 1)
        #expect(scripts.sources[0].contains(#"do script "fortiChromeMain""#))
    }

    @Test func terminalAutomationDeniedGivesClearMessage() async {
        let scripts = FakeScripts()
        scripts.error = ScriptError(number: ScriptError.automationDenied, message: "not allowed")
        let r = ActionRunner(ax: FakeAX(), process: FakeProcess(), clock: FakeClock(), scripts: scripts)
        let report = await r.run(ProfileAction(name: "t", steps: [.terminalCommand(command: "ls", app: TerminalApp.iTerm)]))
        #expect(report.steps[0].status == .failed)
        #expect(report.steps[0].error == "Allow Windows Manager to control iTerm2 in System Settings > Privacy & Security > Automation")
    }

    private func pressRun(_ node: FakeNode, mode: ClickMode? = nil) async -> (ActionRunReport, FakeAX) {
        let ax = FakeAX()
        ax.roots = [FakeNode("AXWindow", [node])]
        let l = ElementLocator(bundleID: "app.x", path: [ElementMatcher(role: node.role ?? "")], clickMode: mode)
        let r = await runner(ax).run(ProfileAction(name: "p", steps: [.press(locator: l)]))
        return (r, ax)
    }

    @Test func pressFallbackOrder() async {
        let n = FakeNode("AXScrollArea")
        n.pressResult = false; n.pickResult = true
        var (r, ax) = await pressRun(n)
        #expect(n.order == ["press", "AXConfirm", "AXPick"])
        #expect(r.steps[0].summary.hasSuffix("(via AXPick)"))
        #expect(ax.clicks.isEmpty)

        let m = FakeNode("AXScrollArea")
        m.pressResult = false; m.center = CGPoint(x: 10, y: 20); m.focusable = true
        (r, ax) = await pressRun(m)
        #expect(m.order == ["press", "AXConfirm", "AXPick", "focus"])
        #expect(ax.activated == ["app.x"])
        #expect(ax.clicks == [CGPoint(x: 10, y: 20)])
        #expect(r.steps[0].summary.hasSuffix("(via click)"))

        let plain = FakeNode("AXButton")
        (r, _) = await pressRun(plain)
        #expect(plain.order == ["press"])
        #expect(r.steps[0].summary == "press app.x / AXButton")
    }

    @Test func pointerModeClicksStraightAway() async {
        let n = FakeNode("AXGroup")
        n.center = CGPoint(x: 5, y: 6)
        let (r, ax) = await pressRun(n, mode: .pointer)
        #expect(n.order == ["focus"])
        #expect(ax.clicks == [CGPoint(x: 5, y: 6)])
        #expect(r.succeeded)
    }

    @Test func pressFailsWhenNothingWorks() async {
        let n = FakeNode("AXGroup")
        n.pressResult = false
        let (r, _) = await pressRun(n)
        #expect(r.steps[0].status == .failed)
    }
}
