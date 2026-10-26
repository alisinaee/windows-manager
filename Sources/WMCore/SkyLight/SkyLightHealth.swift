import Foundation

/// What the SkyLight bridge can do on this Mac right now, and what the app does without each capability.
///
/// `evaluate` is pure: it only looks at the symbol and class tables it is given, so tests can use a fake table.
/// `current()` probes the real SkyLight through `PrivateSymbols` (the one loader in the project) and runs one
/// read-only self-test. It never changes a window or a Desktop.
public struct SkyLightHealth: Codable, Equatable {
    public enum Overall: String, Codable, Equatable {
        /// Everything the app uses is present.
        case ok
        /// Reading works, but at least one write or per-window capability is missing; the app falls back.
        case degraded
        /// Desktop (Space) reads are missing or broken; Desktop-aware features are off.
        case unavailable
    }

    /// Result of the live read-only check made by `current()`.
    public struct SelfTest: Codable, Equatable {
        public var ok: Bool
        /// Active Space id from `SLSGetActiveSpace` (0 when it could not be read).
        public var activeSpaceID: UInt64
        /// Number of displays `SLSCopyManagedDisplaySpaces` reported.
        public var displayCount: Int
        public var elapsedMilliseconds: Double
        public var error: String?
    }

    /// `ProcessInfo.operatingSystemVersionString` at the time of the check.
    public var macOS: String
    public var overall: Overall
    /// Read the Desktop list and the active Desktop (`SLSMainConnectionID`, `SLSCopyManagedDisplaySpaces`, `SLSGetActiveSpace`).
    public var canReadSpaces: Bool
    /// Move windows to another Desktop (`SLSMoveWindowsToManagedSpace`, or the bridged operation class).
    public var canMoveWindowsToSpace: Bool
    /// Ask which Desktops a window is on (`SLSCopySpacesForWindows`).
    public var canReadWindowSpaces: Bool
    /// Names of the probed symbols and classes that are missing, in probe order.
    public var missing: [String]
    /// One line per missing capability (and for a failed self-test or a missing SkyLight), ready to show to people.
    public var fallbacks: [String]
    /// nil for `evaluate` without a live check, and for a static evaluation.
    public var selfTest: SelfTest?

    // MARK: Probed names

    public static let mainConnectionSymbol = "SLSMainConnectionID"
    public static let readSymbols = ["SLSCopyManagedDisplaySpaces", "SLSGetActiveSpace"]
    public static let moveSymbol = "SLSMoveWindowsToManagedSpace"
    public static let moveClass = "SLSBridgedMoveWindowsToManagedSpaceOperation"
    public static let windowSpacesSymbol = "SLSCopySpacesForWindows"

    /// Every SkyLight symbol `current()` looks up.
    public static let probedSymbols = [
        mainConnectionSymbol,
        "SLSCopyManagedDisplaySpaces",
        "SLSGetActiveSpace",
        moveSymbol,
        windowSpacesSymbol,
    ]

    /// Every ObjC class `current()` looks up.
    public static let probedClasses = [moveClass]

    // MARK: Pure evaluation

    /// Computes the flags, fallback lines and overall state from a symbol table and a class table.
    /// - Parameters:
    ///   - symbols: symbol name -> exported (true) or not. A missing key counts as not exported.
    ///   - classes: ObjC class name -> exists (true).
    ///   - osVersion: the macOS version string, copied into the result.
    ///   - loadError: the dlopen error when SkyLight did not load, shown as the first fallback line.
    ///   - selfTest: the live check result. A failed check turns `canReadSpaces` off.
    public static func evaluate(symbols: [String: Bool],
                                classes: [String: Bool],
                                osVersion: String,
                                loadError: String? = nil,
                                selfTest: SelfTest? = nil) -> SkyLightHealth {
        func has(_ name: String) -> Bool { symbols[name] ?? false }
        func hasClass(_ name: String) -> Bool { classes[name] ?? false }

        var readSpaces = has(mainConnectionSymbol) && readSymbols.allSatisfy(has)
        let moveWindows = has(moveSymbol) || hasClass(moveClass)
        let readWindowSpaces = has(mainConnectionSymbol) && has(windowSpacesSymbol)

        var selfTestFailed = false
        if let selfTest, !selfTest.ok { selfTestFailed = true; readSpaces = false }

        var missing = probedSymbols.filter { !has($0) }
        missing += probedClasses.filter { !hasClass($0) }

        var fallbacks: [String] = []
        if let loadError {
            fallbacks.append("SkyLight could not be loaded (\(loadError)); every Desktop feature is off.")
        }
        if !readSpaces {
            fallbacks.append("Desktop list cannot be read; Desktop-aware features are off and windows are not grouped by Desktop.")
        }
        if !moveWindows {
            fallbacks.append("moving windows between Desktops is disabled; windows are placed on the current Desktop only")
        }
        if !readWindowSpaces {
            fallbacks.append("the Desktop of each window cannot be read; only windows on the current Desktop are matched.")
        }
        if selfTestFailed, let error = selfTest?.error {
            fallbacks.append("the read-only SkyLight self-test failed (\(error)); Desktop reads are treated as unavailable.")
        }

        let overall: Overall
        if !readSpaces {
            overall = .unavailable
        } else if !moveWindows || !readWindowSpaces {
            overall = .degraded
        } else {
            overall = .ok
        }

        return SkyLightHealth(macOS: osVersion,
                              overall: overall,
                              canReadSpaces: readSpaces,
                              canMoveWindowsToSpace: moveWindows,
                              canReadWindowSpaces: readWindowSpaces,
                              missing: missing,
                              fallbacks: fallbacks,
                              selfTest: selfTest)
    }

    // MARK: Live probe

    /// Probes the real SkyLight. Cheap: a few symbol lookups, plus one read of the active Space and the display
    /// list when reads are available. No window or Desktop is changed. Call it off the main thread when possible.
    public static func current() -> SkyLightHealth {
        var symbols: [String: Bool] = [:]
        for name in probedSymbols { symbols[name] = PrivateSymbols.exists(name) }
        var classes: [String: Bool] = [:]
        for name in probedClasses { classes[name] = NSClassFromString(name) != nil }
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let loadError = PrivateSymbols.isLoaded ? nil : (PrivateSymbols.loadError ?? "unknown error")

        let staticResult = evaluate(symbols: symbols, classes: classes, osVersion: version, loadError: loadError)
        guard staticResult.canReadSpaces else { return staticResult }
        return evaluate(symbols: symbols, classes: classes, osVersion: version, loadError: loadError,
                        selfTest: runSelfTest())
    }

    /// One read of the active Space and the display list. Reads only.
    static func runSelfTest() -> SelfTest {
        let clock = ContinuousClock()
        let start = clock.now
        let activeID = SpaceReader.activeSpaceID()
        var displayCount = 0
        var failure: String?
        do {
            displayCount = try SpaceReader.displays().count
        } catch {
            failure = error.localizedDescription
        }
        let elapsed = start.duration(to: clock.now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15

        if failure == nil, activeID == 0 { failure = "SLSGetActiveSpace returned 0" }
        if failure == nil, displayCount == 0 { failure = "no displays reported" }
        return SelfTest(ok: failure == nil,
                        activeSpaceID: activeID,
                        displayCount: displayCount,
                        elapsedMilliseconds: milliseconds,
                        error: failure)
    }
}
