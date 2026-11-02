import Foundation
import Testing
@testable import WMCore

private final class FakeNode: RecorderNode, @unchecked Sendable {
    var role: String?
    var subrole: String?
    var title: String?
    var identifier: String?
    var descriptionText: String?
    var value: String?
    var pid: pid_t
    var parentNode: FakeNode?
    var kids: [FakeNode] = []

    init(_ role: String, title: String? = nil, identifier: String? = nil, desc: String? = nil,
         subrole: String? = nil, pid: pid_t = 100, kids: [FakeNode] = []) {
        self.role = role; self.title = title; self.identifier = identifier; self.descriptionText = desc
        self.subrole = subrole; self.pid = pid; self.kids = kids
        for k in kids { k.parentNode = self }
    }
    func children() -> [any AXNode] { kids }
    func press() -> Bool { true }
    func focus() -> Bool { true }
    func parent() -> (any RecorderNode)? { parentNode }
    func isSame(as other: any RecorderNode) -> Bool { (other as? FakeNode) === self }
}

private final class FakeSource: RecorderEventSource, @unchecked Sendable {
    var handler: (@Sendable (RecorderEvent) -> Void)?
    func start(_ handler: @escaping @Sendable (RecorderEvent) -> Void) -> Bool { self.handler = handler; return true }
    func stop() { handler = nil }
    func send(_ e: RecorderEvent) { handler?(e) }
}

private final class FakeInspector: RecorderInspector, @unchecked Sendable {
    var hit: FakeNode?
    var focused: FakeNode?
    var bundles: [pid_t: String] = [100: "com.example.app", 200: "com.example.other", 300: "com.apple.Terminal", 999: "com.wm.self"]
    func element(at point: CGPoint) -> (any RecorderNode)? { hit }
    func focusedElement() -> (any RecorderNode)? { focused }
    func bundleID(forPID pid: pid_t) -> String? { bundles[pid] }
}

/// Steps with the press timeout stripped to make comparisons short.
private func pressLocators(_ steps: [ActionStep]) -> [ElementLocator] {
    steps.compactMap { if case .press(let l, _, _) = $0 { return l }; return nil }
}

@Suite final class ActionRecorderTests {
    private let source = FakeSource()
    private let inspector = FakeInspector()
    private let recorder: ActionRecorder
    private var t: TimeInterval = 0

    init() {
        recorder = ActionRecorder(source: source, inspector: inspector, selfPID: 999)
        #expect(recorder.start())
    }

    private func click(_ node: FakeNode, after dt: TimeInterval = 1) {
        t += dt; inspector.hit = node
        source.send(RecorderEvent(kind: .mouseDown, timestamp: t))
    }
    private func type(_ chars: String, code: UInt16 = 0, mods: KeyCombo.Modifiers = [], after dt: TimeInterval = 0.1) {
        t += dt
        source.send(RecorderEvent(kind: .keyDown, keyCode: code, characters: chars, modifiers: mods,
                                  timestamp: t, targetPID: 100))
    }
    private func button(_ title: String) -> FakeNode {
        let b = FakeNode("AXButton", title: title)
        _ = FakeNode("AXWindow", title: "Main", kids: [FakeNode("AXGroup", kids: [b])])
        return b
    }

    @Test func locatorSkipsWindowAndEmptyGroups() {
        let b = FakeNode("AXButton", title: "Save", identifier: "saveBtn")
        let tool = FakeNode("AXToolbar", identifier: "main-toolbar", kids: [b])
        let win = FakeNode("AXWindow", title: "Doc", kids: [FakeNode("AXGroup", kids: [tool])])
        _ = FakeNode("AXApplication", kids: [win])
        click(b)
        let steps = recorder.stop()
        #expect(steps.count == 2)
        #expect(steps[0] == .launchApp(bundleID: "com.example.app"))
        #expect(pressLocators(steps) == [ElementLocator(bundleID: "com.example.app", path: [
            ElementMatcher(role: "AXToolbar", identifier: "main-toolbar"),
            ElementMatcher(role: "AXButton", identifier: "saveBtn")],
            structural: [StructuralHop(role: "AXGroup", index: 0), StructuralHop(role: "AXToolbar", index: 0),
                         StructuralHop(role: "AXButton", index: 0)],
            windowIndex: 0, windowTitle: "Doc")])
    }

    @Test func descriptionUsedAndIndexOnlyWhenAmbiguous() {
        let a = FakeNode("AXButton", desc: "Close"), b = FakeNode("AXButton", desc: "Close")
        let c = FakeNode("AXButton", desc: "Open")
        _ = FakeNode("AXWindow", kids: [a, b, c])
        click(b); click(c)
        let locs = pressLocators(recorder.stop())
        #expect(locs[0].path == [ElementMatcher(role: "AXButton", description: "Close", index: 1)])
        #expect(locs[1].path == [ElementMatcher(role: "AXButton", description: "Open")])
    }

    @Test func menuPathAndLaunchOncePerApp() {
        let item = FakeNode("AXMenuItem", title: "New Window")
        let file = FakeNode("AXMenuBarItem", title: "File", kids: [FakeNode("AXMenu", kids: [item])])
        _ = FakeNode("AXMenuBar", kids: [file])
        click(item); click(item)
        let m = ActionStep.menu(bundleID: "com.example.app", path: ["File", "New Window"])
        #expect(recorder.stop() == [.launchApp(bundleID: "com.example.app"), m, m])
    }

    @Test func menuBarItemAndSubmenuParentEmitNothing() {
        let leaf = FakeNode("AXMenuItem", title: "PNG")
        let exportItem = FakeNode("AXMenuItem", title: "Export", kids: [FakeNode("AXMenu", kids: [leaf])])
        let file = FakeNode("AXMenuBarItem", title: "File", kids: [FakeNode("AXMenu", kids: [exportItem])])
        _ = FakeNode("AXMenuBar", kids: [file])
        click(file); click(exportItem); click(leaf)
        #expect(recorder.stop() == [.launchApp(bundleID: "com.example.app"),
                                    .menu(bundleID: "com.example.app", path: ["File", "Export", "PNG"])])
    }

    @Test func textMergesAndFlushesBeforeClick() {
        type("h"); type("i"); type(" "); type("!")
        click(button("OK"))
        type("x")
        let steps = recorder.stop()
        #expect(steps.count == 4)
        #expect(steps[0] == .launchApp(bundleID: "com.example.app"))
        #expect(steps[1] == .typeText(text: "hi !", into: nil))
        #expect(pressLocators([steps[2]]).count == 1)
        #expect(steps[3] == .typeText(text: "x", into: nil))
    }

    @Test func backspaceEditsPendingText() {
        type("a"); type("b"); type("", code: 51)
        #expect(recorder.stop().last == .typeText(text: "a", into: nil))
    }

    @Test func comboAndSpecialKeys() {
        type("t", code: KeyCombo.keyCodes["t"]!, mods: [.command, .shift])
        type("\r", code: 36)
        type("\t", code: 48, mods: [.shift])
        type("\u{1B}", code: 53)
        type("c", code: 8, mods: [.control, .option])
        let keys = recorder.stop().compactMap { s -> String? in if case .key(let k) = s { return k }; return nil }
        #expect(keys == ["cmd+shift+t", "return", "shift+tab", "escape", "ctrl+opt+c"])
        for k in keys { #expect(KeyCombo.parse(k) != nil) }
    }

    @Test func secureFieldSkippedBySubroleAndRole() {
        inspector.focused = FakeNode("AXTextField", subrole: "AXSecureTextField")
        type("s"); type("e"); type("v", code: 9, mods: .command)
        #expect(recorder.skippedSecureInput)
        #expect(recorder.stop().isEmpty)

        let r2 = ActionRecorder(source: source, inspector: inspector, selfPID: 999)
        inspector.focused = FakeNode("AXSecureTextField")
        #expect(r2.start())
        type("p"); type("\r", code: 36)
        #expect(r2.skippedSecureInput)
        #expect(r2.stop() == [.key(combo: "return")])
    }

    @Test func selfPidIgnored() {
        click(FakeNode("AXButton", title: "Record", pid: 999))
        inspector.focused = FakeNode("AXTextField", pid: 999)
        type("a")
        #expect(recorder.stop().isEmpty)
    }

    @Test func systemUIClicksAndKeysNotRecorded() {
        #expect(ActionRecorder.systemUIBundleIDs.contains("com.apple.WindowManager"))
        #expect(ActionRecorder.systemUIBundleIDs.contains("com.apple.loginwindow"))
        inspector.bundles[300] = "com.apple.WindowManager"
        click(FakeNode("AXButton", title: "test", pid: 300))
        inspector.focused = FakeNode("AXTextField", pid: 300)
        type("a")
        type("\r", code: 36)
        #expect(recorder.stop().isEmpty)
    }

    @Test func duplicatePressesWithin300msDropped() {
        let b = button("Go")
        click(b); click(b, after: 0.2); click(b, after: 0.5)
        #expect(pressLocators(recorder.stop()).count == 2)
    }

    @Test func otherAppEmitsLaunchOnce() {
        click(button("A"))
        let other = FakeNode("AXButton", title: "B", pid: 200)
        click(other); click(other)
        let launches = recorder.stop().filter { if case .launchApp = $0 { return true }; return false }
        #expect(launches == [.launchApp(bundleID: "com.example.app"), .launchApp(bundleID: "com.example.other")])
    }

    @Test func eventsAfterStopIgnored() {
        _ = recorder.stop()
        source.send(RecorderEvent(kind: .keyDown, characters: "a"))
        #expect(!recorder.isRecording)
        #expect(recorder.steps.isEmpty)
    }

    // MARK: P9.12

    @Test func promptStripping() {
        #expect(ActionRecorder.stripPrompt("ali@mac ~ % fortiChromeMain") == "fortiChromeMain")
        #expect(ActionRecorder.stripPrompt("➜  windows_manager git:(main) ✗ ls") == "ls")
        #expect(ActionRecorder.stripPrompt("➜  windows_manager ls -la") == "ls -la")
        #expect(ActionRecorder.stripPrompt("user@host:~$ echo 5 % 3") == "echo 5 % 3")
        #expect(ActionRecorder.stripPrompt("user@host:~ $ echo 5 % 3") == "echo 5 % 3")
        #expect(ActionRecorder.stripPrompt("root@h:/# make") == "make")
        #expect(ActionRecorder.stripPrompt("~/code ❯ git status") == "git status")
        #expect(ActionRecorder.stripPrompt("ali@mac ~ % ") == nil)
        #expect(ActionRecorder.terminalCommand(fromTerminalText: "Last login\nali@mac ~ % ls\n\n") == "ls")
    }

    private func terminalText(_ value: String) -> (area: FakeNode, focused: FakeNode) {
        let area = FakeNode("AXTextArea", title: "shell", pid: 300)
        _ = FakeNode("AXWindow", title: "bash", pid: 300, kids: [FakeNode("AXScrollArea", pid: 300, kids: [area])])
        area.value = value
        inspector.focused = area
        return (area, area)
    }

    private func terminalKey(_ code: UInt16, _ chars: String) {
        t += 0.1
        source.send(RecorderEvent(kind: .keyDown, keyCode: code, characters: chars, timestamp: t, targetPID: 300))
    }

    @Test func historyArrowsCollapseToOneTerminalCommand() {
        let (area, _) = terminalText("Last login: today\nali@mac ~ % fortiChromeMain")
        click(area)
        for _ in 0..<8 { terminalKey(126, "\u{F700}") }
        terminalKey(36, "\r")
        #expect(recorder.stop() == [.launchApp(bundleID: "com.apple.Terminal"),
                                    .terminalCommand(command: "fortiChromeMain", app: "com.apple.Terminal", newWindow: false)])
    }

    @Test func typedCommandsCollapseSeparately() {
        let (area, _) = terminalText("ali@mac ~ % ls")
        click(area)
        terminalKey(0, "l"); terminalKey(1, "s"); terminalKey(36, "\r")
        area.value = "ali@mac ~ % ls\nfile\nali@mac ~ % pwd"
        terminalKey(35, "p"); terminalKey(36, "\r")
        #expect(recorder.stop() == [.launchApp(bundleID: "com.apple.Terminal"),
                                    .terminalCommand(command: "ls", app: "com.apple.Terminal", newWindow: false),
                                    .terminalCommand(command: "pwd", app: "com.apple.Terminal", newWindow: false)])
    }

    @Test func unreadableTerminalCommandKeepsRawSteps() {
        let (area, _) = terminalText("no prompt here")
        click(area)
        terminalKey(126, "\u{F700}")
        terminalKey(36, "\r")
        #expect(recorder.stop() == [.launchApp(bundleID: "com.apple.Terminal"), .key(combo: "up"), .key(combo: "return")])
    }

    @Test func nonPressableContainersRecordAsPointerClicks() {
        let scroll = FakeNode("AXScrollArea", title: "Who's using Chrome?")
        _ = FakeNode("AXWindow", title: "Chrome", kids: [scroll])
        click(scroll)
        let b = button("Go"); click(b)
        let locs = pressLocators(recorder.stop())
        #expect(locs[0].clickMode == .pointer)
        #expect(locs[1].clickMode == nil)
    }
}
