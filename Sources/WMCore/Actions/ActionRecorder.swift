import AppKit
import ApplicationServices
import Foundation

/// An AX element the recorder can walk upward from.
public protocol RecorderNode: AXNode {
    var pid: pid_t { get }
    func parent() -> (any RecorderNode)?
    func isSame(as other: any RecorderNode) -> Bool
}

/// Hit testing and app lookups the recorder needs. The real one uses the system-wide AX element.
public protocol RecorderInspector: Sendable {
    func element(at point: CGPoint) -> (any RecorderNode)?
    func focusedElement() -> (any RecorderNode)?
    func bundleID(forPID pid: pid_t) -> String?
}

/// RecorderNode over a real AXUIElement.
public final class SystemRecorderNode: RecorderNode, @unchecked Sendable {
    private let base: AXElementNode
    private var element: AXElement { base.element }
    public init(_ element: AXElement) { base = AXElementNode(element) }

    public var role: String? { base.role }
    public var subrole: String? { base.subrole }
    public var title: String? { base.title }
    public var identifier: String? { base.identifier }
    public var descriptionText: String? { base.descriptionText }
    public var value: String? { base.value }
    public func children() -> [any AXNode] { base.children() }
    public func press() -> Bool { base.press() }
    public func focus() -> Bool { base.focus() }
    public var pid: pid_t { element.pid ?? 0 }
    public func parent() -> (any RecorderNode)? { element.element(kAXParentAttribute).map { SystemRecorderNode($0) } }
    public func isSame(as other: any RecorderNode) -> Bool {
        guard let o = other as? SystemRecorderNode else { return false }
        return element == o.element
    }
}

public struct SystemRecorderInspector: RecorderInspector {
    public init() {}

    public func element(at point: CGPoint) -> (any RecorderNode)? {
        guard AXPermission.isTrusted() else { return nil }
        var hit: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(AXElement.systemWide.raw, Float(point.x), Float(point.y), &hit)
        guard err == .success, let hit else { return nil }
        return SystemRecorderNode(AXElement(hit))
    }

    public func focusedElement() -> (any RecorderNode)? {
        guard AXPermission.isTrusted() else { return nil }
        return AXElement.systemWide.element(kAXFocusedUIElementAttribute).map { SystemRecorderNode($0) }
    }

    public func bundleID(forPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}

/// Turns what the user does (clicks and key presses) into profile action steps. No AI: clicks become
/// element locators, menu bar clicks become menu paths, typing becomes text and key combos.
public final class ActionRecorder: @unchecked Sendable {
    public static let duplicateWindow: TimeInterval = 0.3

    /// macOS system UI (Stage Manager, Dock, menu extras, Spotlight, login window). Clicks and keys aimed
    /// at these apps are not recorded: they are not app steps the user wants replayed.
    public static let systemUIBundleIDs: Set<String> = [
        "com.apple.WindowManager", "com.apple.dock", "com.apple.controlcenter", "com.apple.systemuiserver",
        "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.loginwindow",
    ]

    private struct Entry {
        var step: ActionStep
        var time: TimeInterval
    }

    private let source: any RecorderEventSource
    private let inspector: any RecorderInspector
    private let selfPID: pid_t
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var pendingText = ""
    private var pendingLocator: ElementLocator?
    private var pendingTime: TimeInterval = 0
    private var launched: Set<String> = []
    private var recording = false
    private var secureSkipped = false

    public init(source: any RecorderEventSource = EventTapSource(),
                inspector: any RecorderInspector = SystemRecorderInspector(),
                selfPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.source = source; self.inspector = inspector; self.selfPID = selfPID
    }

    public var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return recording }
    /// True when text was typed into a password field and left out of the recording.
    public var skippedSecureInput: Bool { lock.lock(); defer { lock.unlock() }; return secureSkipped }
    /// The cleaned steps recorded so far (also available while recording).
    public var steps: [ActionStep] {
        lock.lock(); defer { lock.unlock() }
        var all = entries
        if !pendingText.isEmpty { all.append(Entry(step: .typeText(text: pendingText, into: pendingLocator), time: pendingTime)) }
        return Self.cleanupTimed(all).map(\.step)
    }

    /// Starts listening. Returns false when the event source could not start.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        guard !recording else { lock.unlock(); return true }
        entries = []; pendingText = ""; pendingLocator = nil; launched = []; secureSkipped = false
        recording = true
        lock.unlock()
        let ok = source.start { [weak self] event in self?.handle(event) }
        if !ok { lock.lock(); recording = false; lock.unlock() }
        return ok
    }

    /// Stops listening and returns the recorded steps.
    @discardableResult
    public func stop() -> [ActionStep] { stopTimed().map(\.step) }

    /// Stops listening and returns the recorded steps with the time each one happened.
    @discardableResult
    public func stopTimed() -> [TimedStep] {
        source.stop()
        lock.lock(); defer { lock.unlock() }
        recording = false
        flushText()
        return Self.cleanupTimed(entries)
    }

    // MARK: Event handling

    func handle(_ event: RecorderEvent) {
        lock.lock(); defer { lock.unlock() }
        guard recording else { return }
        switch event.kind {
        case .mouseDown: handleMouse(event)
        case .keyDown: handleKey(event)
        case .flagsChanged: break
        }
    }

    private func handleMouse(_ event: RecorderEvent) {
        if event.targetPID == selfPID { return }
        guard let node = inspector.element(at: event.location) else { return }
        if node.pid == selfPID { return }
        guard let bundle = inspector.bundleID(forPID: node.pid) else { return }
        flushText()
        if Self.systemUIBundleIDs.contains(bundle) { return }
        noteApp(bundle, time: event.timestamp)
        var chain: [any RecorderNode] = [node]
        while let p = chain.last?.parent(), chain.count < 64 { chain.append(p) }

        if chain.contains(where: { $0.role == "AXMenuBar" }) {
            // Items below the menu bar, top down; AXMenu containers carry no title of their own.
            let titled = chain.reversed().filter { $0.role == "AXMenuBarItem" || $0.role == "AXMenuItem" }
            if let leaf = titled.last, leaf.role == "AXMenuItem",
               !leaf.children().contains(where: { $0.role == "AXMenu" }) {
                let path = titled.compactMap { $0.title }.filter { !$0.isEmpty }
                if path.count == titled.count { entries.append(Entry(step: .menu(bundleID: bundle, path: path), time: event.timestamp)) }
            }
            return
        }
        guard let locator = Self.locator(bundleID: bundle, chain: chain) else { return }
        entries.append(Entry(step: .press(locator: locator), time: event.timestamp))
    }

    private func handleKey(_ event: RecorderEvent) {
        if event.targetPID == selfPID { return }
        let focused = inspector.focusedElement()
        if let focused, focused.pid == selfPID { return }
        let keyBundle = focused.flatMap { inspector.bundleID(forPID: $0.pid) }
            ?? event.targetPID.flatMap { inspector.bundleID(forPID: $0) }
        if let keyBundle, Self.systemUIBundleIDs.contains(keyBundle) { flushText(); return }
        let isSpecial = Self.specialKeys[event.keyCode] != nil
        if let focused, Self.isSecure(focused) {
            flushText()
            // Return/Tab/Escape carry no secret and keep the flow intact (submit the form).
            if isSpecial, !event.modifiers.contains(.command) { appendKey(event) } else { secureSkipped = true }
            return
        }
        if let focused, let bundle = inspector.bundleID(forPID: focused.pid) {
            noteApp(bundle, time: event.timestamp)
        } else if let pid = event.targetPID, let bundle = inspector.bundleID(forPID: pid) {
            noteApp(bundle, time: event.timestamp)
        }
        let combo = !event.modifiers.isDisjoint(with: [.command, .control, .option])
        // Backspace inside pending text edits it instead of becoming a key step.
        if event.keyCode == 51, !combo, !pendingText.isEmpty { pendingText.removeLast(); return }
        if combo || isSpecial {
            flushText()
            appendKey(event)
            return
        }
        guard Self.isPrintable(event.characters) else {
            flushText()
            if Self.name(forKeyCode: event.keyCode) != nil { appendKey(event) }
            return
        }
        if pendingText.isEmpty {
            pendingTime = event.timestamp
            pendingLocator = focused.flatMap { Self.textRoles.contains($0.role ?? "") ? Self.locator(bundleID: inspector.bundleID(forPID: $0.pid) ?? "", chain: Self.chain(from: $0)) : nil }
        }
        pendingText += event.characters
    }

    private func appendKey(_ event: RecorderEvent) {
        guard let combo = Self.comboString(keyCode: event.keyCode, modifiers: event.modifiers) else { return }
        flushText()
        entries.append(Entry(step: .key(combo: combo), time: event.timestamp))
    }

    private func flushText() {
        guard !pendingText.isEmpty else { return }
        entries.append(Entry(step: .typeText(text: pendingText, into: pendingLocator), time: pendingTime))
        pendingText = ""; pendingLocator = nil
    }

    private func noteApp(_ bundle: String, time: TimeInterval) {
        guard bundle != Bundle.main.bundleIdentifier, launched.insert(bundle).inserted else { return }
        flushText()
        entries.append(Entry(step: .launchApp(bundleID: bundle), time: time))
    }

    // MARK: Pure helpers

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Keys recorded as `.key` steps even without a modifier.
    private static let specialKeys: [UInt16: String] = [36: "return", 76: "return", 48: "tab", 53: "escape"]

    static func isSecure(_ node: any AXNode) -> Bool {
        node.role == "AXSecureTextField" || node.subrole == "AXSecureTextField"
    }

    static func isPrintable(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { u in
            u.value >= 0x20 && u.value != 0x7F && !(0xF700...0xF8FF).contains(u.value)
        }
    }

    private static let reverseKeyCodes: [UInt16: String] = {
        var map: [UInt16: String] = [:]
        let aliases: Set<String> = ["enter", "esc", "backspace"]
        for (name, code) in KeyCombo.keyCodes where !aliases.contains(name) { map[code] = name }
        return map
    }()

    static func name(forKeyCode code: UInt16) -> String? {
        if code == 76 { return "return" }
        return reverseKeyCodes[code]
    }

    /// "cmd+shift+t" style text that `KeyCombo.parse` reads back.
    static func comboString(keyCode: UInt16, modifiers: KeyCombo.Modifiers) -> String? {
        guard let key = name(forKeyCode: keyCode) else { return nil }
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        return (parts + [key]).joined(separator: "+")
    }

    static func chain(from node: any RecorderNode) -> [any RecorderNode] {
        var chain: [any RecorderNode] = [node]
        while let p = chain.last?.parent(), chain.count < 64 { chain.append(p) }
        return chain
    }

    /// Builds a locator from `chain` (element first, then its ancestors up to the app root).
    /// Application and window levels are left out (the search starts at the windows); intermediate
    /// containers without any identifying text are skipped because the search descends through them.
    static func locator(bundleID: String, chain: [any RecorderNode]) -> ElementLocator? {
        guard let target = chain.first, !bundleID.isEmpty else { return nil }
        var matchers: [ElementMatcher] = []
        for (i, node) in chain.enumerated() {
            let role = node.role ?? ""
            if role == "AXApplication" || role == "AXWindow" || role.isEmpty && i > 0 { continue }
            let identifier = nonEmpty(node.identifier)
            let title = nonEmpty(node.title)
            let desc = (identifier == nil && title == nil) ? nonEmpty(node.descriptionText) : nil
            if i > 0, identifier == nil, title == nil, desc == nil { continue }
            // Window chrome buttons keep their subrole so the analyzer can tell them from app buttons.
            let chrome = i == 0 ? node.subrole.flatMap { chromeSubroles.contains($0) ? $0 : nil } : nil
            var m = ElementMatcher(role: role, subrole: chrome, title: identifier == nil ? title : nil,
                                   identifier: identifier, description: desc)
            if identifier == nil, ElementMatcher.looksLikeSymbolName(title) || ElementMatcher.looksLikeSymbolName(desc) {
                m.volatile = true
            }
            if let parent = i + 1 < chain.count ? chain[i + 1] : nil {
                let same = parent.children().filter { sib in
                    m.rank(role: sib.role, subrole: sib.subrole, title: sib.title, identifier: sib.identifier,
                           description: sib.descriptionText) != nil
                }
                if same.count > 1 {
                    m.index = same.firstIndex(where: { sib in (sib as? any RecorderNode).map { node.isSame(as: $0) } ?? false })
                }
            }
            matchers.append(m)
        }
        _ = target
        guard !matchers.isEmpty else { return nil }
        var locator = ElementLocator(bundleID: bundleID, path: matchers.reversed())
        applyStructure(to: &locator, chain: chain)
        return locator
    }

    /// Records where the element sits: the window (index among the app's windows, title) and, below it,
    /// role + index among same-role siblings at every level.
    private static func applyStructure(to locator: inout ElementLocator, chain: [any RecorderNode]) {
        guard let windowPos = chain.firstIndex(where: { $0.role == "AXWindow" }) else { return }
        let window = chain[windowPos]
        var hops: [StructuralHop] = []
        for i in stride(from: windowPos - 1, through: 0, by: -1) {
            let node = chain[i]
            let parent = chain[i + 1]
            let role = node.role ?? ""
            let same = parent.children().filter { $0.role == role }
            guard let idx = same.firstIndex(where: { sib in (sib as? any RecorderNode).map { node.isSame(as: $0) } ?? false })
            else { return }
            hops.append(StructuralHop(role: role, index: idx))
        }
        guard !hops.isEmpty else { return }
        locator.structural = hops
        locator.windowTitle = nonEmpty(window.title)
        if windowPos + 1 < chain.count {
            let windows = chain[windowPos + 1].children().filter { $0.role == "AXWindow" }
            locator.windowIndex = windows.firstIndex(where: { sib in (sib as? any RecorderNode).map { window.isSame(as: $0) } ?? false })
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// Drops a press on the same locator that follows another within `duplicateWindow` seconds.
    private static func cleanupTimed(_ list: [Entry]) -> [TimedStep] {
        var out: [Entry] = []
        for e in list {
            if case .press(let l) = e.step, let last = out.last, case .press(let l2) = last.step, l == l2,
               e.time - last.time <= duplicateWindow { continue }
            out.append(e)
        }
        return out.map { TimedStep(step: $0.step, time: $0.time) }
    }

    /// Subroles of the close / minimize / zoom / full-screen buttons of a window.
    public static let chromeSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
    ]
}

/// A recorded step and when it happened (seconds on the event clock).
public struct TimedStep: Equatable, Sendable {
    public var step: ActionStep
    public var time: TimeInterval
    public init(step: ActionStep, time: TimeInterval) { self.step = step; self.time = time }
}
