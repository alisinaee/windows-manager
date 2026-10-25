import AppKit
import Foundation
import ObjectiveC

// Moves windows to another Desktop (Space) through private SkyLight calls and checks by reading the
// window's Space back. Ideas and C signatures follow the MIT-licensed yabai project
// (https://github.com/asmvik/yabai: src/space_manager.c, src/misc/extern.h, src/yabai.c); the code is our own.
// The note that AppKit must be loaded for WindowServer to honour the move comes from the MIT-licensed
// ferry project (https://github.com/softmaxe/ferry).
//
// What the macOS 27.0.1 investigation found (see SkyLightImage):
//  - SLSMoveWindowsToManagedSpace still exists but does nothing since macOS 14.5.
//  - The working call is the bridged operation: build an `SLSBridgedMoveWindowsToManagedSpaceOperation`
//    with `initWithWindows:spaceID:` and hand it to SLSPerformAsynchronousBridgedWindowManagementOperation.
//  - That C function is no longer exported. It is still in SkyLight's symbol table as a local symbol
//    `__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation`
//    (yabai master looks up exactly this name). Its body is `[SLSWMBridgeDelegate() performAsynchronous...:op]`,
//    and the Objective-C method `-[SLSAsynchronousBridgedWindowManagementOperation performWithWMBridgeDelegate]`
//    makes the identical call, so the operation can also perform itself through the runtime.
//  - SLSWMBridgeDelegate() is the delegate set with SLSWindowManagementBridgeSetDelegate, or else a
//    SLSWindowManagementFallbackBridge that forwards to WMClientWindowManager. That class lives in
//    WindowManagement.framework, which AppKit loads; this is why the move needs AppKit in the process.

/// The ways we know to move a window to another Space, in the order they are tried.
public enum MoveMethod: String, CaseIterable, Codable {
    /// Bridged operation performed through the exported C function (macOS 14.5 up to some 26.x builds).
    case bridgedExported
    /// Bridged operation performed through the same function found by scanning SkyLight's symbol table
    /// (it is no longer exported on 27.0.1), or through `-performWithWMBridgeDelegate` when the scan fails.
    case bridgedScanned
    /// The old "compat id" trick: tag the Space, assign the windows to that workspace, clear the tag.
    case compatID
    /// `SLSMoveWindowsToManagedSpace`, which silently does nothing on current macOS.
    case legacy
}

/// Whether one method can be tried on this Mac, with the reason.
public struct MethodAvailability: Codable, Equatable {
    public var available: Bool
    public var reason: String

    public init(available: Bool, reason: String) {
        self.available = available
        self.reason = reason
    }
}

/// What happened when one method was tried.
public struct MethodAttempt: Codable, Equatable {
    public var method: MoveMethod
    /// False when the method was skipped because it is not available (then `detail` says why).
    public var invoked: Bool
    /// What was called and what it returned, or why nothing was called.
    public var detail: String
    /// True when the read-back showed every window on the target Space.
    public var verified: Bool
    /// True when the move only showed up after the 1 s polling window (during the extra wait).
    public var late: Bool
    /// Seconds from the call until the read-back matched; nil when it never did.
    public var secondsToVerify: Double?
    /// Window id (as text) -> Space ids from the last read-back of this attempt.
    public var spacesAfter: [String: [UInt64]]

    public init(method: MoveMethod, invoked: Bool, detail: String, verified: Bool = false, late: Bool = false,
                secondsToVerify: Double? = nil, spacesAfter: [String: [UInt64]] = [:]) {
        self.method = method
        self.invoked = invoked
        self.detail = detail
        self.verified = verified
        self.late = late
        self.secondsToVerify = secondsToVerify
        self.spacesAfter = spacesAfter
    }
}

/// The record of one `SpaceMover.move` call.
public struct MoveOutcome: Codable, Equatable {
    public var windowIDs: [UInt32]
    public var targetSpaceID: UInt64
    /// The method the caller asked for; nil means "try all in order".
    public var requestedMethod: MoveMethod?
    /// Window id (as text) -> Space ids before anything was called.
    public var spacesBefore: [String: [UInt64]]
    /// True when every window was already on the target Space; nothing was called.
    public var alreadyOnTarget: Bool
    /// True when AppKit was initialised in this process before the call (WindowServer ignores moves otherwise).
    public var appKitReady: Bool
    /// One entry per method looked at, in order, including skipped ones.
    public var attempts: [MethodAttempt]
    /// The method whose read-back matched; nil when none did.
    public var succeededWith: MoveMethod?
    /// Window id (as text) -> Space ids from the final read-back.
    public var verifiedSpaces: [String: [UInt64]]
    /// Seconds for the whole call.
    public var elapsed: Double

    public init(windowIDs: [UInt32], targetSpaceID: UInt64, requestedMethod: MoveMethod?,
                spacesBefore: [String: [UInt64]] = [:], alreadyOnTarget: Bool = false, appKitReady: Bool = false,
                attempts: [MethodAttempt] = [], succeededWith: MoveMethod? = nil,
                verifiedSpaces: [String: [UInt64]] = [:], elapsed: Double = 0) {
        self.windowIDs = windowIDs
        self.targetSpaceID = targetSpaceID
        self.requestedMethod = requestedMethod
        self.spacesBefore = spacesBefore
        self.alreadyOnTarget = alreadyOnTarget
        self.appKitReady = appKitReady
        self.attempts = attempts
        self.succeededWith = succeededWith
        self.verifiedSpaces = verifiedSpaces
        self.elapsed = elapsed
    }

    /// The windows are on the target Space, either already or after a verified move.
    public var success: Bool { alreadyOnTarget || succeededWith != nil }
}

// MARK: - Choosing the target (pure)

/// Where a move should go: the Nth Desktop of the window's display, or a specific Space id.
public enum MoveTargetRequest: Equatable {
    /// 1-based "Desktop N" number on the display the window is on (full-screen Spaces are not counted).
    case desktopNumber(Int)
    case spaceID(UInt64)
}

/// A resolved move: from which Desktop to which Desktop.
public struct MovePlan: Codable, Equatable {
    public var sourceSpaceID: UInt64
    public var sourceDisplay: String
    public var sourceDesktopNumber: Int
    public var targetSpaceID: UInt64
    public var targetDisplay: String
    public var targetDesktopNumber: Int

    public init(sourceSpaceID: UInt64, sourceDisplay: String, sourceDesktopNumber: Int,
                targetSpaceID: UInt64, targetDisplay: String, targetDesktopNumber: Int) {
        self.sourceSpaceID = sourceSpaceID
        self.sourceDisplay = sourceDisplay
        self.sourceDesktopNumber = sourceDesktopNumber
        self.targetSpaceID = targetSpaceID
        self.targetDisplay = targetDisplay
        self.targetDesktopNumber = targetDesktopNumber
    }

    /// The window is already on the target Desktop.
    public var isNoOp: Bool { sourceSpaceID == targetSpaceID }
    public var isCrossDisplay: Bool { sourceDisplay != targetDisplay }
}

public enum MovePlanError: Error, LocalizedError, Equatable {
    case windowOnNoSpace
    case windowOnSeveralSpaces(Int)
    case unknownSpace(UInt64)
    case sourceNotDesktop(String)
    case targetNotDesktop(UInt64, String)
    case noSuchDesktop(number: Int, available: Int, display: String)

    public var errorDescription: String? {
        switch self {
        case .windowOnNoSpace:
            return "The window is on no Space (menu bar overlay, hidden helper window or Stage Manager window)."
        case .windowOnSeveralSpaces(let count):
            return "The window is on \(count) Spaces (assigned to all Desktops?). Only windows on exactly one Desktop can be moved and put back."
        case .unknownSpace(let id):
            return "Space \(id) does not exist on any display."
        case .sourceNotDesktop(let what):
            return "The window is in \(what), not on a Desktop. Only windows on a Desktop can be moved."
        case .targetNotDesktop(let id, let what):
            return "Space \(id) is \(what), not a Desktop. Windows can only be moved to a Desktop."
        case .noSuchDesktop(let number, let available, let display):
            return "Desktop \(number) does not exist on display \(display) (it has \(available) Desktop\(available == 1 ? "" : "s"))."
        }
    }
}

public enum SpaceMover {
    // MARK: Private signatures and names

    /// `void/id SLSPerform...(id operation)`; the return value is ignored.
    private typealias PerformOperation = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias MoveWindowsToManagedSpace = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias SpaceSetCompatID = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SetWindowListWorkspace = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, Int32) -> Int32
    private typealias InitOperation = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> Unmanaged<AnyObject>?

    static let exportedPerformName = "SLSPerformAsynchronousBridgedWindowManagementOperation"
    /// Local C++ symbol of the same function on macOS 27 (the same name yabai master looks up).
    static let internalPerformName =
        "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"
    static let operationClassName = "SLSBridgedMoveWindowsToManagedSpaceOperation"
    static let performSelectorName = "performWithWMBridgeDelegate"
    /// 'yabe', the workspace tag yabai used for the compat-id trick.
    static let compatWorkspace: Int32 = 0x79616265

    // MARK: Target resolution (pure)

    /// Works out source and target Desktop for a window.
    /// - Parameters:
    ///   - windowSpaceIDs: the Space ids the window is on (`SpaceReader.spaces(forWindows:)`).
    ///   - target: "Desktop N on the window's display" or a Space id.
    ///   - displays: `SpaceReader.displays()` or a fixture.
    public static func plan(windowSpaceIDs: [UInt64], target: MoveTargetRequest,
                            displays: [DisplaySpaces]) throws -> MovePlan {
        guard !windowSpaceIDs.isEmpty else { throw MovePlanError.windowOnNoSpace }
        guard windowSpaceIDs.count == 1 else { throw MovePlanError.windowOnSeveralSpaces(windowSpaceIDs.count) }
        let sourceID = windowSpaceIDs[0]

        guard let (sourceDisplay, source) = find(spaceID: sourceID, in: displays) else {
            throw MovePlanError.unknownSpace(sourceID)
        }
        guard source.kind == .desktop, let sourceNumber = sourceDisplay.desktopNumber(of: source) else {
            throw MovePlanError.sourceNotDesktop(describe(source))
        }

        let targetDisplay: DisplaySpaces
        let targetSpace: SpaceInfo
        switch target {
        case .desktopNumber(let number):
            let desktops = sourceDisplay.spaces.filter { $0.kind == .desktop }
            guard number >= 1, number <= desktops.count else {
                throw MovePlanError.noSuchDesktop(number: number, available: desktops.count,
                                                  display: sourceDisplay.displayIdentifier)
            }
            targetDisplay = sourceDisplay
            targetSpace = desktops[number - 1]
        case .spaceID(let id):
            guard let (display, space) = find(spaceID: id, in: displays) else { throw MovePlanError.unknownSpace(id) }
            guard space.kind == .desktop else { throw MovePlanError.targetNotDesktop(id, describe(space)) }
            targetDisplay = display
            targetSpace = space
        }

        return MovePlan(sourceSpaceID: source.id, sourceDisplay: sourceDisplay.displayIdentifier,
                        sourceDesktopNumber: sourceNumber,
                        targetSpaceID: targetSpace.id, targetDisplay: targetDisplay.displayIdentifier,
                        targetDesktopNumber: targetDisplay.desktopNumber(of: targetSpace) ?? 0)
    }

    private static func find(spaceID: UInt64, in displays: [DisplaySpaces]) -> (DisplaySpaces, SpaceInfo)? {
        for display in displays {
            if let space = display.spaces.first(where: { $0.id == spaceID }) { return (display, space) }
        }
        return nil
    }

    /// "a full-screen Space (Google Chrome)", "a Split View Space (Safari + Notes)", "a Desktop", "a system Space".
    static func describe(_ space: SpaceInfo) -> String {
        let apps = space.ownerAppNames.isEmpty ? "" : " (\(space.ownerAppNames.joined(separator: " + ")))"
        switch space.kind {
        case .desktop: return "a Desktop"
        case .fullscreen: return (space.isSplitView ? "a Split View Space" : "a full-screen Space") + apps
        case .other(let raw): return "a Space of type \(raw)"
        }
    }

    /// True when every window is on exactly the target Space (and there is at least one window).
    public static func isMoved(spaces: [UInt32: [UInt64]], windows: [UInt32], target: UInt64) -> Bool {
        !windows.isEmpty && windows.allSatisfy { spaces[$0] == [target] }
    }

    // MARK: Availability

    private struct Resolved {
        var reason: String
        /// Nil when the method cannot be used here.
        var run: ((_ windows: [UInt32], _ space: UInt64) -> String)?
    }

    /// Per method: can it be tried on this Mac, and why.
    public static func availability() -> [MoveMethod: MethodAvailability] {
        var result: [MoveMethod: MethodAvailability] = [:]
        for method in MoveMethod.allCases {
            let resolved = resolve(method)
            result[method] = MethodAvailability(available: resolved.run != nil, reason: resolved.reason)
        }
        return result
    }

    /// Per method: a sentence saying why it is available or not, starting with "available:" or "not available:".
    public static func availableMethods() -> [MoveMethod: String] {
        availability().mapValues { ($0.available ? "available: " : "not available: ") + $0.reason }
    }

    private static func resolve(_ method: MoveMethod) -> Resolved {
        guard PrivateSymbols.isLoaded else {
            return Resolved(reason: "SkyLight could not be loaded" + (PrivateSymbols.loadError.map { ": \($0)" } ?? ""))
        }
        switch method {
        case .bridgedExported: return resolveBridgedExported()
        case .bridgedScanned: return resolveBridgedScanned()
        case .compatID: return resolveCompatID()
        case .legacy: return resolveLegacy()
        }
    }

    private static func resolveBridgedExported() -> Resolved {
        guard NSClassFromString(operationClassName) != nil else {
            return Resolved(reason: "class \(operationClassName) does not exist")
        }
        guard let perform = PrivateSymbols.lookup(exportedPerformName, as: PerformOperation.self) else {
            return Resolved(reason: "SkyLight does not export \(exportedPerformName) (dlsym returns nil)")
        }
        return Resolved(reason: "exported \(exportedPerformName) found, class \(operationClassName) exists") { windows, space in
            runBridged(windows: windows, space: space, via: .function(perform, "exported \(exportedPerformName)"))
        }
    }

    private static func resolveBridgedScanned() -> Resolved {
        guard let cls = NSClassFromString(operationClassName) else {
            return Resolved(reason: "class \(operationClassName) does not exist")
        }

        #if !arch(arm64e)
        // Exact local name first (the one yabai master uses), then any non-method symbol that contains the
        // exported name, in case a later macOS changes the C++ mangling.
        var symbol = SkyLightImage.symbol(named: internalPerformName)
        if symbol == nil {
            symbol = SkyLightImage.symbols(containing: [exportedPerformName]).first { !$0.isObjCMethod }
        }
        if let symbol, symbol.address != 0, let pointer = UnsafeRawPointer(bitPattern: UInt(symbol.address)) {
            let perform = unsafeBitCast(pointer, to: PerformOperation.self)
            let reason = "internal function \(symbol.name) at 0x\(String(symbol.address, radix: 16)) "
                + "(unslid 0x\(String(symbol.unslidAddress, radix: 16)), \(symbol.isExported ? "exported" : "not exported")), "
                + "found in SkyLight's symbol table"
            return Resolved(reason: reason) { windows, space in
                runBridged(windows: windows, space: space, via: .function(perform, "scanned \(symbol.name)"))
            }
        }
        #endif

        // The function is only a wrapper around this method, so it does the same job (also the way to go
        // in an arm64e build, where a raw address would need pointer signing).
        let selector = NSSelectorFromString(performSelectorName)
        if class_getInstanceMethod(cls, selector) != nil {
            let why = SkyLightImage.problem.map { " (symbol scan unavailable: \($0))" } ?? " (symbol not found in the symbol table)"
            return Resolved(reason: "using -\(performSelectorName) of the operation class\(why)") { windows, space in
                runBridged(windows: windows, space: space, via: .selector)
            }
        }
        return Resolved(reason: "no internal function found in SkyLight's symbol table and the operation has no -\(performSelectorName)")
    }

    private static func resolveCompatID() -> Resolved {
        guard let connection = PrivateSymbols.lookup("SLSMainConnectionID", as: MainConnectionID.self),
              let setCompat = PrivateSymbols.lookup("SLSSpaceSetCompatID", as: SpaceSetCompatID.self),
              let setWorkspace = PrivateSymbols.lookup("SLSSetWindowListWorkspace", as: SetWindowListWorkspace.self)
        else {
            return Resolved(reason: "SkyLight does not export SLSSpaceSetCompatID and SLSSetWindowListWorkspace")
        }
        return Resolved(reason: "SLSSpaceSetCompatID and SLSSetWindowListWorkspace are exported (reported not to work on recent macOS)") { windows, space in
            let cid = connection()
            var ids = windows
            let first = setCompat(cid, space, compatWorkspace)
            let second = ids.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return setWorkspace(cid, base, Int32(buffer.count), compatWorkspace)
            }
            let third = setCompat(cid, space, 0)
            return "SLSSpaceSetCompatID(\(space), 0x79616265)=\(first), "
                + "SLSSetWindowListWorkspace(\(windows.count) window(s))=\(second), SLSSpaceSetCompatID(\(space), 0)=\(third)"
        }
    }

    private static func resolveLegacy() -> Resolved {
        guard let connection = PrivateSymbols.lookup("SLSMainConnectionID", as: MainConnectionID.self),
              let move = PrivateSymbols.lookup("SLSMoveWindowsToManagedSpace", as: MoveWindowsToManagedSpace.self)
        else {
            return Resolved(reason: "SkyLight does not export SLSMoveWindowsToManagedSpace")
        }
        return Resolved(reason: "SLSMoveWindowsToManagedSpace is exported (known to do nothing since macOS 14.5)") { windows, space in
            let list = windows.map { NSNumber(value: Int32(bitPattern: $0)) } as CFArray
            move(connection(), list, space)
            return "SLSMoveWindowsToManagedSpace(\(windows.count) window(s), \(space)) returned (no result value)"
        }
    }

    // MARK: Bridged operation

    private enum BridgeRoute {
        case function(PerformOperation, String)
        case selector
    }

    /// Builds the operation object without performing it: `[[SLSBridgedMoveWindowsToManagedSpaceOperation alloc]
    /// initWithWindows:spaceID:]`. The window list is an array of 32-bit numbers like yabai passes.
    static func makeOperation(windows: [UInt32], spaceID: UInt64) -> (operation: NSObject?, detail: String) {
        guard let cls = NSClassFromString(operationClassName) else {
            return (nil, "class \(operationClassName) does not exist")
        }
        let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
        guard let initMethod = class_getInstanceMethod(cls, initSelector) else {
            return (nil, "\(operationClassName) has no initWithWindows:spaceID:")
        }
        // alloc returns an owned (+1) object; init consumes it and returns the owned result.
        guard let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc")) else {
            return (nil, "alloc returned nil")
        }
        let initFunction = unsafeBitCast(method_getImplementation(initMethod), to: InitOperation.self)
        let list = windows.map { NSNumber(value: Int32(bitPattern: $0)) } as NSArray
        guard let made = initFunction(allocated.takeUnretainedValue(), initSelector, list, spaceID) else {
            return (nil, "initWithWindows:spaceID: returned nil")
        }
        guard let operation = made.takeRetainedValue() as? NSObject else {
            return (nil, "the operation is not an NSObject")
        }
        return (operation, "built \(String(cString: class_getName(type(of: operation)))) with \(windows.count) window(s), space \(spaceID)")
    }

    private static func runBridged(windows: [UInt32], space: UInt64, via route: BridgeRoute) -> String {
        let built = makeOperation(windows: windows, spaceID: space)
        guard let operation = built.operation else { return "could not build the operation: \(built.detail)" }
        switch route {
        case .function(let perform, let origin):
            _ = perform(UnsafeRawPointer(Unmanaged.passUnretained(operation).toOpaque()))
            return "\(built.detail); performed through \(origin)"
        case .selector:
            _ = operation.perform(NSSelectorFromString(performSelectorName))
            return "\(built.detail); performed through -\(performSelectorName)"
        }
    }

    /// Read-only check for the probe: builds an operation for no windows and Space 0 without performing it,
    /// and reports whether the selectors the bridged route needs are there.
    public static func describeOperationConstruction() -> String {
        guard PrivateSymbols.isLoaded else { return "SkyLight is not loaded" }
        let built = makeOperation(windows: [], spaceID: 0)
        guard let operation = built.operation else { return "could not build the operation: \(built.detail)" }
        let responds = operation.responds(to: NSSelectorFromString(performSelectorName))
        let readBack = (operation.value(forKey: "spaceID") as? NSNumber).map { "spaceID reads back \($0)" } ?? "spaceID not readable"
        return "\(built.detail) (not performed); \(readBack); responds to -\(performSelectorName): \(responds ? "yes" : "NO")"
    }

    // MARK: AppKit

    /// WindowServer ignores the bridged move unless AppKit is loaded and the process is a registered app
    /// (ferry). Touching NSApplication.shared does that; a menu-bar-less accessory app is the least visible
    /// kind. Returns false when this is not the main thread (NSApplication must be created there).
    @discardableResult
    public static func prepareAppKit() -> Bool {
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            let app = NSApplication.shared
            if app.activationPolicy() == .prohibited { app.setActivationPolicy(.accessory) }
            return true
        }
    }

    // MARK: Moving

    /// Read-back: window id -> Space ids.
    private static func snapshot(_ windows: [UInt32]) -> [UInt32: [UInt64]] {
        SpaceReader.spaces(forWindows: windows)
    }

    private static func keyed(_ spaces: [UInt32: [UInt64]], _ windows: [UInt32]) -> [String: [UInt64]] {
        var result: [String: [UInt64]] = [:]
        for window in windows { result[String(window)] = spaces[window] ?? [] }
        return result
    }

    /// Moves windows to the Space `toSpace` and checks that they got there.
    /// With `method` nil the methods are tried in `MoveMethod.allCases` order until the read-back matches;
    /// with a method only that one is tried. After each call the Space of every window is read back every
    /// 50 ms for up to 1 s; if it still does not match, it is read once more after 2 s (the move may land late).
    /// The main run loop keeps spinning while waiting, because the bridge hands work to it.
    public static func move(windowIDs: [UInt32], toSpace target: UInt64, method: MoveMethod? = nil) -> MoveOutcome {
        let start = ProcessInfo.processInfo.systemUptime
        var outcome = MoveOutcome(windowIDs: windowIDs, targetSpaceID: target, requestedMethod: method)

        outcome.appKitReady = prepareAppKit()
        let before = snapshot(windowIDs)
        outcome.spacesBefore = keyed(before, windowIDs)

        if isMoved(spaces: before, windows: windowIDs, target: target) {
            outcome.alreadyOnTarget = true
            outcome.verifiedSpaces = outcome.spacesBefore
            outcome.elapsed = ProcessInfo.processInfo.systemUptime - start
            return outcome
        }

        for candidate in (method.map { [$0] } ?? MoveMethod.allCases) {
            let attempt = attempt(candidate, windows: windowIDs, target: target)
            outcome.attempts.append(attempt)
            if attempt.verified {
                outcome.succeededWith = candidate
                break
            }
        }

        outcome.verifiedSpaces = keyed(snapshot(windowIDs), windowIDs)
        outcome.elapsed = ProcessInfo.processInfo.systemUptime - start
        return outcome
    }

    private static func attempt(_ method: MoveMethod, windows: [UInt32], target: UInt64) -> MethodAttempt {
        let resolved = resolve(method)
        guard let run = resolved.run else {
            return MethodAttempt(method: method, invoked: false, detail: "skipped, not available: \(resolved.reason)")
        }

        let called = ProcessInfo.processInfo.systemUptime
        let detail = run(windows, target)

        var verified = false
        var late = false
        var seconds: Double?
        var last: [UInt32: [UInt64]] = [:]

        if waitUntil(timeout: 1.0, interval: 0.05, {
            last = snapshot(windows)
            return isMoved(spaces: last, windows: windows, target: target)
        }) != nil {
            verified = true
            seconds = ProcessInfo.processInfo.systemUptime - called
        } else {
            // One more look after 2 s, in case the window server is slow.
            _ = waitUntil(timeout: 2.0, interval: 0.05) { false }
            last = snapshot(windows)
            if isMoved(spaces: last, windows: windows, target: target) {
                verified = true
                late = true
                seconds = ProcessInfo.processInfo.systemUptime - called
            }
        }

        return MethodAttempt(method: method, invoked: true, detail: detail, verified: verified, late: late,
                             secondsToVerify: seconds, spacesAfter: keyed(last, windows))
    }
}
