import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// AXNode over a real AXUIElement.
public final class AXElementNode: AXNode, @unchecked Sendable {
    let element: AXElement
    public init(_ element: AXElement) { self.element = element }

    public var role: String? { element.role }
    public var subrole: String? { element.subrole }
    public var title: String? { element.title }
    public var identifier: String? { element.string("AXIdentifier") }
    public var descriptionText: String? { element.string(kAXDescriptionAttribute) }
    public var value: String? {
        guard let v = element.value(kAXValueAttribute) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    public func children() -> [any AXNode] { element.elements(kAXChildrenAttribute).map { AXElementNode($0) } }
    public func press() -> Bool { element.perform(kAXPressAction).isSuccess }
    public func focus() -> Bool {
        if element.set(kAXFocusedAttribute, true).isSuccess { return true }
        return element.perform(kAXPressAction).isSuccess
    }
}

public struct SystemAXProvider: AXProvider {
    public init() {}

    private func app(_ bundleID: String) -> AXElement? {
        guard AXPermission.isTrusted(),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        return AXElement.application(pid: running.processIdentifier)
    }

    public func roots(bundleID: String) -> [any AXNode] {
        guard let app = app(bundleID) else { return [] }
        let windows = app.elements(kAXWindowsAttribute)
        return (windows.isEmpty ? [app] : windows).map { AXElementNode($0) }
    }

    public func menuBar(bundleID: String) -> (any AXNode)? {
        app(bundleID)?.element(kAXMenuBarAttribute).map { AXElementNode($0) }
    }

    public func sendKey(_ combo: KeyCombo) throws {
        var flags: CGEventFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: down) else {
                throw ActionError.failed("could not create key event")
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    public func typeText(_ text: String) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else {
                    throw ActionError.failed("could not create key event")
                }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.post(tap: .cghidEventTap)
            }
            usleep(8_000)
        }
    }
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func runShell(_ command: String, waitForExit: Bool, timeout: TimeInterval) async throws -> ShellResult {
        try await run(executable: "/bin/zsh", arguments: ["-lc", command], waitForExit: waitForExit, timeout: timeout)
    }

    public func runShortcut(_ name: String, timeout: TimeInterval) async throws -> ShellResult {
        try await run(executable: "/usr/bin/shortcuts", arguments: ["run", name], waitForExit: true, timeout: timeout)
    }

    public func launchApp(bundleID: String, timeout: TimeInterval) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw ActionError.failed("app not installed: \(bundleID)")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ActionError.timedOut("launch \(bundleID)")
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    public func openURL(_ url: String) async throws {
        guard let parsed = URL(string: url) else { throw ActionError.failed("invalid URL: \(url)") }
        guard await MainActor.run(body: { NSWorkspace.shared.open(parsed) }) else {
            throw ActionError.failed("could not open \(url)")
        }
    }

    private func run(executable: String, arguments: [String], waitForExit: Bool,
                     timeout: TimeInterval) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        if !waitForExit {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return ShellResult(exitCode: 0)
        }
        do { try process.run() } catch { throw ActionError.failed("could not start \(executable): \(error.localizedDescription)") }
        let deadline = Date().addingTimeInterval(timeout)
        let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        while process.isRunning {
            if Task.isCancelled { process.terminate(); throw CancellationError() }
            if Date() >= deadline {
                process.terminate()
                throw ActionError.timedOut(arguments.last ?? executable)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let data = await reader.value
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ShellResult(exitCode: process.terminationStatus, output: String(text.suffix(500)))
    }
}
