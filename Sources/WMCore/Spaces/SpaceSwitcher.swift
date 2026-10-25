import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Switches the active Space (Desktop or full-screen Space) of a display. macOS has no public API for it,
// so four candidate methods are implemented side by side and compared by `spaceslab switch`.
//
// Credits (read for the facts below, code is our own):
// - jurplel/InstantSpaceSwitcher (MIT): the synthetic Dock swipe, i.e. CGEvent type 30 (Dock control) with
//   gesture fields, posted as Began / Changed / Ended; two phases are not enough.
// - pavlohuk/InstantSpaces (MIT, adapted from InstantSpaceSwitcher) and joshuarli/iss (0BSD): the macOS 27
//   variant, which appends a raw IOHID queue payload to the serialized event as field 4205 and posts a
//   companion gesture event (type 29) after every phase.
// - yabai (MIT, src/misc/extern.h): C signatures of SLSManagedDisplaySetCurrentSpace, SLSShowSpaces,
//   SLSHideSpaces and SLSCopyManagedDisplayForSpace.

// MARK: - Public types

/// The ways this lab tries to change the active Space.
public enum SwitchMethod: String, CaseIterable {
    /// A synthetic Dock swipe gesture (same as a three or four finger swipe).
    case swipe
    /// Ctrl+Left / Ctrl+Right ("Move left/right a space"), repeated to reach the target.
    case keys
    /// Ctrl+<n> ("Switch to Desktop n"); Desktops only.
    case number
    /// SkyLight SLSManagedDisplaySetCurrentSpace (+ SLSShowSpaces / SLSHideSpaces). Changes state, may not repaint.
    case sls
}

public enum SwitchDirection: String {
    case left, right, none
}

/// Which swipe event layout to post.
public enum SwipeVariant: String, CaseIterable {
    /// Modern on macOS 27 and later, legacy before.
    case auto
    /// DockControl fields only (works up to macOS 26).
    case legacy
    /// DockControl fields plus the IOHID payload (field 4205) and a companion gesture event.
    case modern
}

/// Whether the screen really showed the new Space after the state changed.
public enum RepaintVerdict: String {
    /// Windows that belong only to the target Space are on screen, none of the source Space.
    case painted
    /// Windows of the source Space are still on screen and none of the target Space.
    case stale
    /// The two Spaces have no distinguishing windows, or both are on screen.
    case unknown
}

/// Knobs for experiments. The defaults are what `switchTo` normally uses.
public struct SwitchOptions {
    public var swipeVariant: SwipeVariant = .auto
    /// Flip the direction sign of the swipe (use when a swipe goes the wrong way on some macOS version).
    public var invertSwipe = false
    /// For `sls`: also call SLSShowSpaces (target) and SLSHideSpaces (source) when the symbols exist.
    public var slsShowHide = true
    /// For `keys` and `number`: post separate modifier key presses instead of only setting key event flags.
    public var pressModifierKeys = false
    /// Pause between repeated steps of `swipe` and `keys` (seconds).
    public var stepDelay: TimeInterval = 0.1
    /// Move the mouse pointer onto the target display first when it is elsewhere (swipes and shortcuts act on
    /// the display under the pointer), and put it back afterwards.
    public var moveCursorToDisplay = true
    /// How long to poll for the new Space (seconds).
    public var verifyTimeout: TimeInterval = 3.0
    /// Poll interval (seconds).
    public var pollInterval: TimeInterval = 0.03
    /// Wait before the on-screen window check, so the switch animation is over (seconds).
    public var paintSettle: TimeInterval = 0.6

    public init() {}
}

/// Whether a method can be used on this Mac right now, and why.
public struct MethodAvailability: Equatable {
    public var method: SwitchMethod
    public var usable: Bool
    public var reason: String

    public init(method: SwitchMethod, usable: Bool, reason: String) {
        self.method = method
        self.usable = usable
        self.reason = reason
    }
}

/// Everything one `switchTo` call learned.
public struct SwitchOutcome {
    public var method: SwitchMethod
    public var displayIdentifier: String
    public var targetSpaceID: UInt64
    public var startSpaceID: UInt64?
    public var startIndex: Int?
    public var targetIndex: Int?
    public var direction: SwitchDirection = .none
    public var stepCount = 0
    /// Events were posted or the private call was made.
    public var attempted = false
    /// SpaceReader reported the target as the display's current Space within the timeout.
    public var reached = false
    /// Seconds from the first post to the moment the target was seen as current (nil when not reached).
    public var elapsed: TimeInterval?
    /// Seconds until the display's current Space first differed from the start (nil when it never did).
    public var firstChange: TimeInterval?
    /// The display's current Space when polling ended.
    public var finalSpaceID: UInt64?
    /// NSWorkspace.activeSpaceDidChangeNotification deliveries since the first post.
    public var notificationCount = 0
    public var notificationDelay: TimeInterval?
    public var repaint: RepaintVerdict?
    /// Why nothing was done or why it failed.
    public var error: String?
    public var notes: [String] = []

    public init(method: SwitchMethod, displayIdentifier: String, targetSpaceID: UInt64) {
        self.method = method
        self.displayIdentifier = displayIdentifier
        self.targetSpaceID = targetSpaceID
    }

    /// Reached, and for `sls` not known to be a stale screen.
    public var worked: Bool { reached && (method != .sls || repaint != .stale) }

    /// One readable line.
    public var summary: String {
        var parts: [String] = []
        let steps = stepCount > 0 ? "\(stepCount) step\(stepCount == 1 ? "" : "s") \(direction.rawValue)" : "no step"
        if let error {
            return "\(method.rawValue): \(attempted ? "failed" : "not attempted") (\(steps)): \(error)"
        }
        if reached {
            parts.append("reached in \(SpaceSwitcher.format(elapsed))")
        } else {
            parts.append("NOT reached within the timeout (display ended on Space \(finalSpaceID.map(String.init) ?? "?"))")
        }
        if let firstChange { parts.append("first change \(SpaceSwitcher.format(firstChange))") }
        if attempted {
            parts.append(notificationCount > 0
                ? "\(notificationCount) space-change notification(s), first at \(SpaceSwitcher.format(notificationDelay))"
                : "no space-change notification")
        }
        if let repaint { parts.append("screen \(repaint.rawValue)") }
        return "\(method.rawValue): \(steps): " + parts.joined(separator: "; ")
    }
}

// MARK: - Symbolic hotkeys

/// One entry of com.apple.symbolichotkeys > AppleSymbolicHotKeys.
public struct SymbolicHotKey: Equatable {
    public var id: Int
    public var name: String
    public var enabled: Bool
    /// Virtual key code, nil when the entry has no key.
    public var keyCode: Int?
    /// CGEventFlags raw value (Ctrl is 0x40000, fn 0x800000 for arrow keys).
    public var modifiers: UInt64?
    /// The entry exists in the plist (otherwise the macOS default is assumed).
    public var inPlist: Bool
    /// The key combo comes from our built-in default table because the entry has no `value`.
    public var comboIsDefault: Bool

    /// Enabled and a key combo is known: a CGEvent with this key and flags triggers it.
    public var isUsable: Bool { enabled && keyCode != nil && modifiers != nil }
    public var combo: String { SymbolicHotKeys.comboText(keyCode: keyCode, modifiers: modifiers) }
}

public enum SymbolicHotKeys {
    public static let moveLeftID = 79
    public static let moveRightID = 81
    /// "Switch to Desktop 1" is 118, Desktop 16 is 133.
    public static let desktopIDs = Array(118...133)
    public static let relevantIDs = [moveLeftID, moveRightID] + desktopIDs

    public static let ctrl: UInt64 = 0x40000
    public static let option: UInt64 = 0x80000
    public static let shift: UInt64 = 0x20000
    public static let command: UInt64 = 0x100000
    public static let fn: UInt64 = 0x800000

    /// Hotkey id for "Switch to Desktop n" (n from 1 to 16), nil outside that range.
    public static func desktopHotKeyID(forDesktop number: Int) -> Int? {
        (1...16).contains(number) ? 117 + number : nil
    }

    public static func name(for id: Int) -> String {
        switch id {
        case moveLeftID: return "Move left a space"
        case moveRightID: return "Move right a space"
        case 118...133: return "Switch to Desktop \(id - 117)"
        default: return "Hotkey \(id)"
        }
    }

    /// What macOS uses when an entry is missing or has no `value`: enabled flag and key combo.
    static func builtInDefault(for id: Int) -> (enabled: Bool, keyCode: Int?, modifiers: UInt64?) {
        switch id {
        case moveLeftID: return (true, 123, ctrl | fn)
        case moveRightID: return (true, 124, ctrl | fn)
        case 118...127:
            // Ctrl+1 ... Ctrl+9, Ctrl+0 (ANSI key codes); off until the user ticks them.
            let codes = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
            return (false, codes[id - 118], ctrl)
        case 128...133: return (false, nil, nil)
        default: return (false, nil, nil)
        }
    }

    /// Reads the live preferences (read-only).
    public static func read() -> [Int: SymbolicHotKey] {
        let raw = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                            "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        return parse(raw ?? [:])
    }

    /// Turns the AppleSymbolicHotKeys dictionary into hotkeys. Pure. Entries of the relevant ids that are
    /// missing get the macOS default; entries without a `value` get the default key combo.
    public static func parse(_ plist: [String: Any]) -> [Int: SymbolicHotKey] {
        var result: [Int: SymbolicHotKey] = [:]
        for (key, value) in plist {
            guard let id = Int(key), let entry = value as? [String: Any] else { continue }
            let fallback = builtInDefault(for: id)
            let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? fallback.enabled

            var keyCode = fallback.keyCode
            var modifiers = fallback.modifiers
            var isDefault = true
            if let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Any], parameters.count >= 3,
               let code = (parameters[1] as? NSNumber)?.intValue,
               let mods = (parameters[2] as? NSNumber)?.uint64Value {
                isDefault = false
                // 65535 means "no key assigned".
                keyCode = code == 65535 ? nil : code
                modifiers = code == 65535 ? nil : mods
            }
            result[id] = SymbolicHotKey(id: id, name: name(for: id), enabled: enabled, keyCode: keyCode,
                                        modifiers: modifiers, inPlist: true, comboIsDefault: isDefault)
        }
        for id in relevantIDs where result[id] == nil {
            let fallback = builtInDefault(for: id)
            result[id] = SymbolicHotKey(id: id, name: name(for: id), enabled: fallback.enabled,
                                        keyCode: fallback.keyCode, modifiers: fallback.modifiers,
                                        inPlist: false, comboIsDefault: true)
        }
        return result
    }

    /// "Ctrl+Left", "Ctrl+Opt+3", "none". The fn flag is not shown (arrow keys always carry it).
    public static func comboText(keyCode: Int?, modifiers: UInt64?) -> String {
        guard let keyCode else { return "none" }
        let mods = modifiers ?? 0
        var parts: [String] = []
        if mods & ctrl != 0 { parts.append("Ctrl") }
        if mods & option != 0 { parts.append("Opt") }
        if mods & shift != 0 { parts.append("Shift") }
        if mods & command != 0 { parts.append("Cmd") }
        parts.append(keyName(keyCode))
        return parts.joined(separator: "+")
    }

    static func keyName(_ keyCode: Int) -> String {
        let names: [Int: String] = [
            123: "Left", 124: "Right", 125: "Down", 126: "Up", 49: "Space", 36: "Return", 48: "Tab",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        ]
        return names[keyCode] ?? "keycode \(keyCode)"
    }
}

// MARK: - Switcher

public enum SpaceSwitcher {
    // MARK: Pure helpers

    /// How many steps left or right lead from one position to another (positions in Mission Control order).
    public static func steps(from currentIndex: Int, to targetIndex: Int) -> (direction: SwitchDirection, count: Int) {
        if targetIndex > currentIndex { return (.right, targetIndex - currentIndex) }
        if targetIndex < currentIndex { return (.left, currentIndex - targetIndex) }
        return (.none, 0)
    }

    /// "1-3, 5, 7-8" from a list of numbers.
    public static func rangeText(_ numbers: [Int]) -> String {
        let sorted = Set(numbers).sorted()
        var parts: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            parts.append(end > index ? "\(sorted[index])-\(sorted[end])" : "\(sorted[index])")
            index = end + 1
        }
        return parts.joined(separator: ", ")
    }

    static func format(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "-" }
        return String(format: "%.3f s", seconds)
    }

    /// Pure decision behind `availableMethods()`.
    static func evaluateMethods(hotKeys: [Int: SymbolicHotKey], axTrusted: Bool, slsSetCurrentSpace: Bool,
                                slsShowHide: Bool, osMajor: Int) -> [MethodAvailability] {
        let noAX = "Accessibility permission is missing for this process (needed to post events); run `spaceslab doctor`"
        var list: [MethodAvailability] = []

        let variant = osMajor >= 27 ? "modern variant (IOHID payload) on macOS \(osMajor)" : "legacy variant on macOS \(osMajor)"
        list.append(axTrusted
            ? MethodAvailability(method: .swipe, usable: true,
                                 reason: "posts a synthetic Dock swipe, \(variant); Mission Control may still ignore it")
            : MethodAvailability(method: .swipe, usable: false, reason: noAX))

        let left = hotKeys[SymbolicHotKeys.moveLeftID]
        let right = hotKeys[SymbolicHotKeys.moveRightID]
        if !axTrusted {
            list.append(MethodAvailability(method: .keys, usable: false, reason: noAX))
        } else if let left, let right, left.isUsable, right.isUsable {
            list.append(MethodAvailability(method: .keys, usable: true,
                                           reason: "\(left.combo) / \(right.combo) are enabled (hotkeys 79 and 81)"))
        } else {
            var problems: [String] = []
            for key in [left, right].compactMap({ $0 }) where !key.isUsable {
                problems.append("\(key.name) (hotkey \(key.id)) is \(key.enabled ? "enabled but has no key" : "disabled")")
            }
            list.append(MethodAvailability(method: .keys, usable: false,
                                           reason: problems.isEmpty ? "hotkeys 79 and 81 not found" : problems.joined(separator: "; ")
                                               + " (System Settings > Keyboard > Keyboard Shortcuts > Mission Control)"))
        }

        let enabledDesktops = (1...16).filter { number in
            SymbolicHotKeys.desktopHotKeyID(forDesktop: number).flatMap { hotKeys[$0] }?.isUsable == true
        }
        if !axTrusted {
            list.append(MethodAvailability(method: .number, usable: false, reason: noAX))
        } else if enabledDesktops.isEmpty {
            list.append(MethodAvailability(method: .number, usable: false,
                                           reason: "no \"Switch to Desktop n\" shortcut (hotkeys 118-133) is enabled; "
                                               + "tick them in System Settings > Keyboard > Keyboard Shortcuts > Mission Control"))
        } else {
            list.append(MethodAvailability(method: .number, usable: true,
                                           reason: "enabled for Desktop \(rangeText(enabledDesktops)) (Desktops only, not full-screen Spaces)"))
        }

        if slsSetCurrentSpace {
            list.append(MethodAvailability(method: .sls, usable: true,
                                           reason: "SLSManagedDisplaySetCurrentSpace found"
                                               + (slsShowHide ? ", with SLSShowSpaces / SLSHideSpaces" : ", SLSShowSpaces / SLSHideSpaces missing")
                                               + "; expected to change state without repainting"))
        } else {
            list.append(MethodAvailability(method: .sls, usable: false,
                                           reason: "SkyLight does not export SLSManagedDisplaySetCurrentSpace"))
        }
        return list
    }

    // MARK: Availability

    /// Each method with a yes/no and the reason, from the live system.
    public static func availableMethods() -> [MethodAvailability] {
        evaluateMethods(hotKeys: SymbolicHotKeys.read(),
                        axTrusted: AXPermission.isTrusted(),
                        slsSetCurrentSpace: PrivateSymbols.exists("SLSManagedDisplaySetCurrentSpace"),
                        slsShowHide: PrivateSymbols.exists("SLSShowSpaces") && PrivateSymbols.exists("SLSHideSpaces"),
                        osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    /// True when the user's trackpad direction is "natural" (the default when the setting was never changed).
    public static func naturalScrolling() -> Bool {
        let value = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication)
        return (value as? NSNumber)?.boolValue ?? true
    }

    /// The swipe variant `auto` resolves to on this Mac.
    public static func resolvedSwipeVariant(_ variant: SwipeVariant = .auto) -> SwipeVariant {
        guard variant == .auto else { return variant }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? .modern : .legacy
    }

    // MARK: Switching

    /// Switches `displayIdentifier` to the given Space with one method and verifies it by polling
    /// SpaceReader. Never throws; every problem ends up in the returned outcome.
    public static func switchTo(spaceID: UInt64, onDisplay displayIdentifier: String, method: SwitchMethod,
                                options: SwitchOptions = SwitchOptions()) -> SwitchOutcome {
        var out = SwitchOutcome(method: method, displayIdentifier: displayIdentifier, targetSpaceID: spaceID)

        let displays: [DisplaySpaces]
        do {
            displays = try SpaceReader.displays()
        } catch {
            out.error = "cannot read Spaces: \(error.localizedDescription)"
            return out
        }
        guard let display = displays.first(where: { $0.displayIdentifier == displayIdentifier }) else {
            out.error = "display \(displayIdentifier) not found"
            return out
        }
        guard let target = display.spaces.first(where: { $0.id == spaceID }) else {
            out.error = "Space \(spaceID) is not on display \(displayIdentifier)"
            return out
        }
        guard let current = display.currentSpace else {
            out.error = "the display reports no current Space"
            return out
        }
        out.startSpaceID = current.id
        out.startIndex = current.index
        out.targetIndex = target.index
        out.finalSpaceID = current.id

        let plan = steps(from: current.index, to: target.index)
        out.direction = plan.direction
        out.stepCount = plan.count
        if plan.count == 0 {
            out.reached = true
            out.elapsed = 0
            out.notes.append("already the current Space, nothing to do")
            return out
        }

        // Check what the method needs and prepare the action. `action` returns an error text, nil when done.
        let action: () -> String?
        switch method {
        case .swipe:
            if let problem = accessibilityProblem() { out.error = problem; return out }
            let variant = resolvedSwipeVariant(options.swipeVariant)
            let natural = naturalScrolling()
            let sign = DockSwipe.sign(direction: plan.direction, variant: variant, naturalScrolling: natural,
                                      invert: options.invertSwipe)
            out.notes.append("swipe variant \(variant.rawValue), sign \(sign > 0 ? "+" : "-")1"
                + " (natural scrolling \(natural ? "on" : "off")\(options.invertSwipe ? ", inverted by option" : ""))")
            let count = plan.count
            let delay = options.stepDelay
            action = {
                for step in 0..<count {
                    if step > 0 { pause(delay) }
                    if let problem = DockSwipe.post(sign: sign, variant: variant) { return problem }
                }
                return nil
            }

        case .keys:
            if let problem = accessibilityProblem() { out.error = problem; return out }
            let hotKeys = SymbolicHotKeys.read()
            let id = plan.direction == .left ? SymbolicHotKeys.moveLeftID : SymbolicHotKeys.moveRightID
            guard let key = hotKeys[id], key.isUsable, let code = key.keyCode, let mods = key.modifiers else {
                out.error = "\(SymbolicHotKeys.name(for: id)) (hotkey \(id)) is disabled or has no key"
                return out
            }
            out.notes.append("keys: \(key.combo) x\(plan.count) (keycode \(code), flags 0x\(String(mods, radix: 16))"
                + "\(key.comboIsDefault ? ", default combo" : ""))")
            let count = plan.count
            let delay = options.stepDelay
            let press = options.pressModifierKeys
            action = {
                for step in 0..<count {
                    if step > 0 { pause(delay) }
                    if let problem = postKey(code: code, flags: mods, pressModifiers: press) { return problem }
                }
                return nil
            }

        case .number:
            if let problem = accessibilityProblem() { out.error = problem; return out }
            guard target.kind == .desktop, let number = display.desktopNumber(of: target) else {
                out.error = "Ctrl+<n> only reaches Desktops, and the target is not a Desktop"
                return out
            }
            guard let id = SymbolicHotKeys.desktopHotKeyID(forDesktop: number) else {
                out.error = "Desktop \(number) has no shortcut (only Desktops 1 to 16 do)"
                return out
            }
            let hotKeys = SymbolicHotKeys.read()
            guard let key = hotKeys[id], key.isUsable, let code = key.keyCode, let mods = key.modifiers else {
                out.error = "Switch to Desktop \(number) (hotkey \(id)) is disabled or has no key"
                return out
            }
            out.notes.append("number: Switch to Desktop \(number) = \(key.combo) (keycode \(code), flags 0x\(String(mods, radix: 16))"
                + "\(key.comboIsDefault ? ", default combo" : ""))")
            let press = options.pressModifierKeys
            action = { postKey(code: code, flags: mods, pressModifiers: press) }

        case .sls:
            let useShowHide = options.slsShowHide
            guard let call = SkyLightSwitch.prepare(displayIdentifier: displayIdentifier, spaceID: spaceID,
                                                    sourceSpaceID: current.id, showHide: useShowHide) else {
                out.error = "SLSManagedDisplaySetCurrentSpace is not available"
                return out
            }
            out.notes.append(call.description)
            action = call.run
        }

        // Listen for the system's own "Space changed" signal, and put the pointer on the right display.
        let listener = SpaceChangeListener()
        var restorePointer: CGPoint?
        if options.moveCursorToDisplay && method != .sls {
            restorePointer = movePointer(toDisplay: displayIdentifier, notes: &out.notes)
        }

        let t0 = ProcessInfo.processInfo.systemUptime
        if let problem = action() {
            out.error = problem
            if let restorePointer { CGWarpMouseCursorPosition(restorePointer) }
            return out
        }
        out.attempted = true

        // Poll the display's current Space.
        var final = current.id
        var firstChange: TimeInterval?
        _ = waitUntil(timeout: options.verifyTimeout, interval: options.pollInterval) {
            guard let now = (try? SpaceReader.displays())?.first(where: { $0.displayIdentifier == displayIdentifier })
            else { return false }
            final = now.currentSpaceID
            if firstChange == nil && now.currentSpaceID != current.id {
                firstChange = ProcessInfo.processInfo.systemUptime - t0
            }
            return now.currentSpaceID == spaceID
        }
        out.finalSpaceID = final
        out.firstChange = firstChange
        if final == spaceID {
            out.reached = true
            out.elapsed = ProcessInfo.processInfo.systemUptime - t0
        }

        if out.reached {
            pause(options.paintSettle)
            let paint = repaintCheck(source: current.id, target: spaceID)
            out.repaint = paint.verdict
            out.notes.append("screen check: \(paint.detail)")
        }
        let times = listener.times.map { $0 - t0 }.filter { $0 >= 0 }
        out.notificationCount = times.count
        out.notificationDelay = times.first
        listener.stop()

        if let restorePointer {
            pause(0.05)
            CGWarpMouseCursorPosition(restorePointer)
        }
        return out
    }

    // MARK: Helpers

    private static func accessibilityProblem() -> String? {
        AXPermission.isTrusted() ? nil
            : "Accessibility permission is missing for this process (needed to post events); run `spaceslab doctor`"
    }

    /// Lets the run loop spin for `seconds` (so notifications keep arriving).
    public static func pause(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        _ = waitUntil(timeout: seconds, interval: min(seconds, 0.02)) { false }
    }

    /// Posts one key press with the given flags. Returns an error text on failure.
    private static func postKey(code: Int, flags: UInt64, pressModifiers: Bool) -> String? {
        let source = CGEventSource(stateID: .hidSystemState)
        let allFlags = CGEventFlags(rawValue: flags)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false) else {
            return "could not create the key event"
        }

        // Modifier key codes: Ctrl 59, Option 58, Shift 56, Command 55.
        let chain: [(mask: CGEventFlags, key: CGKeyCode)] = [(.maskControl, 59), (.maskAlternate, 58),
                                                               (.maskShift, 56), (.maskCommand, 55)]
        var pressed: [(mask: CGEventFlags, key: CGKeyCode)] = []
        var running = CGEventFlags(rawValue: 0)
        if pressModifiers {
            for item in chain where allFlags.contains(item.mask) {
                running.insert(item.mask)
                pressed.append(item)
                if let event = CGEvent(keyboardEventSource: source, virtualKey: item.key, keyDown: true) {
                    event.type = .flagsChanged
                    event.flags = running
                    event.post(tap: .cghidEventTap)
                }
            }
        }
        down.flags = allFlags
        up.flags = allFlags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        // Always release what was pressed, last pressed first.
        for item in pressed.reversed() {
            running.remove(item.mask)
            if let event = CGEvent(keyboardEventSource: source, virtualKey: item.key, keyDown: false) {
                event.type = .flagsChanged
                event.flags = running
                event.post(tap: .cghidEventTap)
            }
        }
        return nil
    }

    private static func displayID(forIdentifier identifier: String) -> CGDirectDisplayID? {
        if identifier == "Main" { return CGMainDisplayID() }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        for id in ids.prefix(Int(count)) {
            if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
               let text = CFUUIDCreateString(nil, uuid) as String?,
               text.caseInsensitiveCompare(identifier) == .orderedSame { return id }
        }
        return nil
    }

    /// Warps the pointer to the middle of the display when it is on another one. Returns the old position
    /// (to restore later) or nil when nothing was moved.
    private static func movePointer(toDisplay identifier: String, notes: inout [String]) -> CGPoint? {
        guard let id = displayID(forIdentifier: identifier), let here = CGEvent(source: nil)?.location else { return nil }
        let bounds = CGDisplayBounds(id)
        if bounds.contains(here) { return nil }
        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
        notes.append("pointer moved onto the target display (from \(Int(here.x)),\(Int(here.y)))")
        pause(0.1)
        return here
    }

    /// Compares the windows that are on screen with those of the two Spaces to see whether the screen was repainted.
    private static func repaintCheck(source: UInt64, target: UInt64) -> (verdict: RepaintVerdict, detail: String) {
        let sourceWindows = Set(SpaceReader.windows(onSpaces: [source]))
        let targetWindows = Set(SpaceReader.windows(onSpaces: [target]))
        let targetOnly = targetWindows.subtracting(sourceWindows)
        let sourceOnly = sourceWindows.subtracting(targetWindows)

        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return (.unknown, "the on-screen window list is not available")
        }
        var onScreen = Set<UInt32>()
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? Int else { continue }
            onScreen.insert(UInt32(truncatingIfNeeded: number))
        }
        let targetVisible = targetOnly.intersection(onScreen).count
        let sourceVisible = sourceOnly.intersection(onScreen).count
        let detail = "\(targetVisible) of \(targetOnly.count) target-only windows and "
            + "\(sourceVisible) of \(sourceOnly.count) source-only windows on screen"
        if targetVisible > 0 && sourceVisible == 0 { return (.painted, detail) }
        if sourceVisible > 0 && targetVisible == 0 { return (.stale, detail) }
        return (.unknown, detail)
    }
}

/// Counts NSWorkspace.activeSpaceDidChangeNotification deliveries (uptime stamps).
private final class SpaceChangeListener {
    private var token: NSObjectProtocol?
    private(set) var times: [TimeInterval] = []

    init() {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.times.append(ProcessInfo.processInfo.systemUptime)
        }
    }

    func stop() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }

    deinit { stop() }
}

// MARK: - SkyLight method

private enum SkyLightSwitch {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetCurrentSpace = @convention(c) (Int32, CFString, UInt64) -> Void
    private typealias ShowHideSpaces = @convention(c) (Int32, CFArray) -> Void
    private typealias CopyDisplayForSpace = @convention(c) (Int32, UInt64) -> Unmanaged<CFString>?

    struct Call {
        var description: String
        var run: () -> String?
    }

    /// Looks up the symbols and returns a call that performs the switch, or nil when the core symbol is missing.
    static func prepare(displayIdentifier: String, spaceID: UInt64, sourceSpaceID: UInt64, showHide: Bool) -> Call? {
        guard let mainConnection = PrivateSymbols.lookup("SLSMainConnectionID", as: MainConnectionID.self),
              let setCurrent = PrivateSymbols.lookup("SLSManagedDisplaySetCurrentSpace", as: SetCurrentSpace.self)
        else { return nil }
        let show = showHide ? PrivateSymbols.lookup("SLSShowSpaces", as: ShowHideSpaces.self) : nil
        let hide = showHide ? PrivateSymbols.lookup("SLSHideSpaces", as: ShowHideSpaces.self) : nil
        let copyDisplay = PrivateSymbols.lookup("SLSCopyManagedDisplayForSpace", as: CopyDisplayForSpace.self)

        let cid = mainConnection()
        // Prefer the display string SkyLight itself reports for the Space; fall back to the identifier we know.
        let reported = copyDisplay?(cid, spaceID)?.takeRetainedValue() as String?
        let displayString = reported ?? displayIdentifier

        var steps = ["SLSManagedDisplaySetCurrentSpace(display \"\(displayString)\""
            + "\(reported == nil ? " [identifier, SLSCopyManagedDisplayForSpace unavailable]" : "")"
            + ", Space \(spaceID))"]
        if show != nil { steps.insert("SLSShowSpaces([\(spaceID)])", at: 0) }
        if hide != nil { steps.append("SLSHideSpaces([\(sourceSpaceID)])") }

        let run: () -> String? = {
            let target = [NSNumber(value: Int64(bitPattern: spaceID))] as CFArray
            let source = [NSNumber(value: Int64(bitPattern: sourceSpaceID))] as CFArray
            show?(cid, target)
            setCurrent(cid, displayString as CFString, spaceID)
            hide?(cid, source)
            return nil
        }
        return Call(description: "sls: " + steps.joined(separator: " -> "), run: run)
    }
}

// MARK: - Synthetic Dock swipe

enum DockSwipe {
    // Undocumented CGEvent field numbers and values (see the credits at the top of this file).
    static let fieldEventType: UInt32 = 55
    static let fieldGestureHIDType: UInt32 = 110
    static let fieldSwipeMotion: UInt32 = 123
    static let fieldSwipeProgress: UInt32 = 124
    static let fieldSwipePositionX: UInt32 = 125
    static let fieldSwipeVelocityX: UInt32 = 129
    static let fieldSwipeVelocityY: UInt32 = 130
    static let fieldGesturePhase: UInt32 = 132
    static let fieldGesturePhaseAlt: UInt32 = 134
    static let fieldZoomDeltaY: UInt32 = 138
    static let fieldTimestampAlt: UInt32 = 169
    static let serializedPayloadField: UInt16 = 4205

    static let eventGesture = 29
    static let eventDockControl = 30
    static let hidDockSwipe = 23
    static let hidVelocity = 9
    static let motionHorizontal = 1
    static let flavorDock = 3
    static let phases = [1, 2, 4]        // began, changed, ended
    static let phaseEnded = 4
    /// Smallest useful progress: a bigger one makes the previous Space flash before landing.
    static let tinyProgress = 0.000016
    static let flingLegacy = 2000.0
    static let flingModern = 9999.0      // 16.16 fixed point tops out near 32767

    /// +1 or -1 for the progress and velocity fields. Legacy: right is +1. Modern (macOS 27): right is -1
    /// with natural scrolling, +1 without. `invert` flips it.
    static func sign(direction: SwitchDirection, variant: SwipeVariant, naturalScrolling: Bool, invert: Bool) -> Double {
        guard direction != .none else { return 0 }
        var sign: Double
        switch variant {
        case .modern:
            sign = direction == .right ? -1 : 1
            if !naturalScrolling { sign = -sign }
        case .legacy, .auto:
            sign = direction == .right ? 1 : -1
        }
        return invert ? -sign : sign
    }

    /// Value as 16.16 fixed point; a non-zero input never becomes zero.
    static func fixed1616(_ value: Double) -> Int32 {
        let scaled = Int32(clamping: Int64(value * 65536.0))
        if scaled == 0 && value != 0 { return value > 0 ? 1 : -1 }
        return scaled
    }

    /// The raw IOHID queue payload macOS 27 expects in field 4205: a 28 byte queue header, a 40 byte fluid
    /// touch gesture record and, for the ended phase, a 28 byte velocity record. Little endian, no padding.
    static func payload(phase: Int, positionX: Double, positionY: Double, progress: Double,
                        velocityX: Double, velocityY: Double, timestamp: UInt64) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let ended = phase == phaseEnded

        // Queue header (28 bytes).
        put(timestamp)              // timestamp
        put(UInt64(0))              // sender id
        put(UInt32(0))              // options
        put(UInt32(0))              // attribute length
        put(UInt32(ended ? 2 : 1))  // event count

        // Fluid touch gesture record (40 bytes).
        put(UInt32(40))                         // size
        put(UInt32(hidDockSwipe))               // type
        put(UInt32((phase & 0xFF) << 24))       // options: phase in the top byte
        put(UInt8(0)); put(UInt8(0)); put(UInt8(0)); put(UInt8(0))  // depth + reserved
        put(fixed1616(positionX))
        put(fixed1616(positionY))
        put(Int32(0))                           // position z
        put(UInt32(0))                          // swipe mask
        put(UInt16(motionHorizontal))           // gesture motion
        put(UInt16(flavorDock))                 // gesture flavor
        put(fixed1616(progress))

        // Velocity record (28 bytes), ended phase only.
        if ended {
            put(UInt32(28))                     // size
            put(UInt32(hidVelocity))            // type
            put(UInt32(0))                      // options
            put(UInt8(1)); put(UInt8(0)); put(UInt8(0)); put(UInt8(0))  // depth + reserved
            put(fixed1616(velocityX))
            put(fixed1616(velocityY))
            put(Int32(0))                       // velocity z
        }
        return data
    }

    /// Serialized event + 2 byte big-endian payload length + 2 byte big-endian field id + payload.
    static func appendPayload(to serialized: Data, payload: Data) -> Data? {
        // The serialized form starts with version 2.
        guard serialized.count >= 4, Array(serialized.prefix(4)) == [0, 0, 0, 2], payload.count <= 0xFFFF else { return nil }
        var out = serialized
        out.append(UInt8(payload.count >> 8))
        out.append(UInt8(payload.count & 0xFF))
        out.append(UInt8(serializedPayloadField >> 8))
        out.append(UInt8(serializedPayloadField & 0xFF))
        out.append(payload)
        return out
    }

    private static func field(_ number: UInt32) -> CGEventField { CGEventField(rawValue: number)! }

    /// Posts one full Began / Changed / Ended sequence. Returns an error text on failure.
    static func post(sign: Double, variant: SwipeVariant) -> String? {
        let modern = variant == .modern
        for phase in phases {
            guard let main = CGEvent(source: nil) else { return "could not create a CGEvent" }
            main.setIntegerValueField(field(fieldEventType), value: Int64(eventDockControl))
            main.setIntegerValueField(field(fieldGestureHIDType), value: Int64(hidDockSwipe))
            main.setIntegerValueField(field(fieldGesturePhase), value: Int64(phase))
            main.setIntegerValueField(field(fieldSwipeMotion), value: Int64(motionHorizontal))
            main.setDoubleValueField(field(fieldSwipeProgress), value: sign * tinyProgress)

            guard modern else {
                // Legacy: the fling velocity goes on every phase.
                main.setDoubleValueField(field(fieldSwipeVelocityX), value: sign * flingLegacy)
                main.setDoubleValueField(field(fieldSwipeVelocityY), value: sign * flingLegacy)
                main.post(tap: .cgSessionEventTap)
                continue
            }

            let stamp = mach_absolute_time()
            main.setIntegerValueField(field(fieldGesturePhaseAlt), value: Int64(phase))
            main.setDoubleValueField(field(fieldZoomDeltaY), value: 3.0)
            main.setDoubleValueField(field(fieldTimestampAlt), value: Double(stamp))
            main.setDoubleValueField(field(fieldSwipePositionX), value: 0.1)
            let velocity = phase == phaseEnded ? sign * flingModern : 0
            if phase == phaseEnded { main.setDoubleValueField(field(fieldSwipeVelocityX), value: velocity) }

            let bytes = payload(phase: phase, positionX: 0.1, positionY: 0, progress: sign * tinyProgress,
                                velocityX: velocity, velocityY: 0, timestamp: main.timestamp != 0 ? main.timestamp : stamp)
            guard let serialized = main.data,
                  let joined = appendPayload(to: serialized as Data, payload: bytes),
                  let augmented = CGEvent(withDataAllocator: nil, data: joined as CFData) else {
                return "could not build the macOS 27 swipe event (event serialization changed?)"
            }
            augmented.post(tap: .cgSessionEventTap)

            // Companion gesture event; the Dock ignores a Dock control event without it.
            guard let companion = CGEvent(source: nil) else { return "could not create a CGEvent" }
            companion.setIntegerValueField(field(fieldEventType), value: Int64(eventGesture))
            companion.post(tap: .cgSessionEventTap)
        }
        return nil
    }
}
