import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One user input event as the recorder sees it.
public struct RecorderEvent: Equatable, Sendable {
    public enum Kind: Sendable { case mouseDown, keyDown, flagsChanged }
    public var kind: Kind
    public var location: CGPoint
    public var keyCode: UInt16
    /// The characters the key produced (empty for mouse events and non-text keys).
    public var characters: String
    public var modifiers: KeyCombo.Modifiers
    public var timestamp: TimeInterval
    /// Process the event is aimed at (frontmost app for keys), when known.
    public var targetPID: pid_t?

    public init(kind: Kind, location: CGPoint = .zero, keyCode: UInt16 = 0, characters: String = "",
                modifiers: KeyCombo.Modifiers = [], timestamp: TimeInterval = 0, targetPID: pid_t? = nil) {
        self.kind = kind; self.location = location; self.keyCode = keyCode; self.characters = characters
        self.modifiers = modifiers; self.timestamp = timestamp; self.targetPID = targetPID
    }
}

/// Feeds events to the recorder. The real one is a listen-only event tap; tests push synthetic events.
public protocol RecorderEventSource: AnyObject, Sendable {
    /// Begins delivering events. Returns false when the source could not start (for example no permission).
    func start(_ handler: @escaping @Sendable (RecorderEvent) -> Void) -> Bool
    func stop()
}

/// Listen-only CGEventTap (leftMouseDown, keyDown, flagsChanged). It never modifies or blocks an event.
public final class EventTapSource: RecorderEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var handler: (@Sendable (RecorderEvent) -> Void)?

    public init() {}

    public func start(_ handler: @escaping @Sendable (RecorderEvent) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard tap == nil else { return true }
        self.handler = handler
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            Unmanaged<EventTapSource>.fromOpaque(refcon).takeUnretainedValue().receive(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { self.handler = nil; return false }
        tap = port
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            self.runLoop = loop
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "wm.action-recorder.tap"
        thread = t
        t.start()
        ready.wait()
        return true
    }

    public func stop() {
        lock.lock()
        let port = tap, loop = runLoop
        tap = nil; runLoop = nil; thread = nil; handler = nil
        lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let loop { CFRunLoopStop(loop) }
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let port = tap; lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        lock.lock(); let handler = handler; lock.unlock()
        guard let handler else { return }
        var mods: KeyCombo.Modifiers = []
        let f = event.flags
        if f.contains(.maskCommand) { mods.insert(.command) }
        if f.contains(.maskShift) { mods.insert(.shift) }
        if f.contains(.maskAlternate) { mods.insert(.option) }
        if f.contains(.maskControl) { mods.insert(.control) }
        let stamp = ProcessInfo.processInfo.systemUptime
        switch type {
        case .leftMouseDown:
            let target = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            handler(RecorderEvent(kind: .mouseDown, location: event.location, modifiers: mods, timestamp: stamp,
                                  targetPID: target > 0 ? target : nil))
        case .keyDown:
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
            let text = String(utf16CodeUnits: chars, count: min(length, 8))
            handler(RecorderEvent(kind: .keyDown, keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                                  characters: text, modifiers: mods, timestamp: stamp,
                                  targetPID: NSWorkspace.shared.frontmostApplication?.processIdentifier))
        case .flagsChanged:
            handler(RecorderEvent(kind: .flagsChanged, modifiers: mods, timestamp: stamp))
        default: break
        }
    }
}
