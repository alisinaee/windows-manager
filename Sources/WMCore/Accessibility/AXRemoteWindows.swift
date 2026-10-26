import ApplicationServices
import CoreGraphics
import Foundation

/// AX elements for windows that are on other Spaces.
///
/// `kAXWindowsAttribute` only lists the windows of the Space that is active right now (plus placeholders for
/// the rest), so a restore that wants to read or set the frame of a window on another Space would have to
/// switch Spaces first. This type avoids that with a long-known private call,
/// `_AXUIElementCreateWithRemoteToken(CFData) -> AXUIElement?`: it builds an element for a given process and
/// *element id* without asking the app to list anything. Element ids are small integers, so we try them one by
/// one and keep the elements that turn out to be windows.
///
/// Token layout (20 bytes, all little-endian), found by experiment on macOS 27:
///
///     0..<4    pid (Int32)
///     4..<8    zero
///     8..<12   0x636f636f (UInt32, so the bytes are 6f 63 6f 63; the byte order "coco" does NOT work)
///     12..<20  element id (UInt64)
///
/// Everything here only reads attributes. Nothing is moved, raised or changed.
///
/// Limits worth knowing:
/// - While the screen is locked macOS answers every window query with placeholders (role AXApplication, no
///   frame) and this lookup finds no windows either; `Resolution.sources` is then empty.
/// - Elements stay usable after their window moves to another Space, but die with the window or the app.
///   The per-pid cache checks that before handing an element out again.
public enum AXRemoteWindows {
    // MARK: Token

    /// Length of a remote token in bytes.
    public static let tokenLength = 20

    /// The constant in the middle of the token, written as a little-endian UInt32.
    public static let tokenMarker: UInt32 = 0x636f636f

    /// The 20 byte token for `_AXUIElementCreateWithRemoteToken`. Pure.
    public static func token(pid: pid_t, elementID: UInt64) -> Data {
        var data = Data(capacity: tokenLength)
        append(UInt32(bitPattern: pid), to: &data)
        append(UInt32(0), to: &data)
        append(tokenMarker, to: &data)
        append(elementID, to: &data)
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    // MARK: Private symbol

    private typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let hiServicesPath =
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"

    /// Resolved once. The symbol lives in HIServices, which the process already has loaded through
    /// ApplicationServices, so a lookup in the global namespace finds it; HIServices is opened by path as a fallback.
    private static let createWithRemoteToken: CreateWithRemoteToken? = {
        let name = "_AXUIElementCreateWithRemoteToken"
        for handle in [dlopen(nil, RTLD_LAZY), dlopen(hiServicesPath, RTLD_LAZY)] {
            if let handle, let symbol = dlsym(handle, name) {
                return unsafeBitCast(symbol, to: CreateWithRemoteToken.self)
            }
        }
        return nil
    }()

    /// True when this macOS version exports `_AXUIElementCreateWithRemoteToken`.
    public static var isAvailable: Bool { createWithRemoteToken != nil }

    // MARK: Cache

    /// Per-pid window cache without any system calls, so its rules can be tested with plain values.
    /// Maps pid -> (CGWindowID -> element).
    struct Cache<Element> {
        private var byPID: [pid_t: [UInt32: Element]] = [:]

        init() {}

        /// Cached windows of `pid`; empty when there are none.
        func windows(pid: pid_t) -> [UInt32: Element] { byPID[pid] ?? [:] }

        /// Pids that have at least one cached window.
        var pids: Set<pid_t> { Set(byPID.keys) }

        /// Adds or replaces windows of `pid`; windows stored earlier stay.
        mutating func store(_ windows: [UInt32: Element], pid: pid_t) {
            guard !windows.isEmpty else { return }
            byPID[pid, default: [:]].merge(windows) { _, new in new }
        }

        /// Drops single windows of `pid` (for example ones whose element went stale).
        mutating func remove(windowIDs: some Sequence<UInt32>, pid: pid_t) {
            guard var windows = byPID[pid] else { return }
            for id in windowIDs { windows[id] = nil }
            byPID[pid] = windows.isEmpty ? nil : windows
        }

        /// Forgets everything about one process.
        mutating func invalidate(pid: pid_t) { byPID[pid] = nil }

        mutating func invalidateAll() { byPID.removeAll() }
    }

    private static let cacheLock = NSLock()
    private static var cache = Cache<AXElement>()

    private static func withCache<R>(_ body: (inout Cache<AXElement>) -> R) -> R {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return body(&cache)
    }

    /// Forgets the cached elements of one process. Call it when the app quits or relaunches, or when a cached
    /// element fails with `.invalidUIElement`.
    public static func invalidate(pid: pid_t) {
        withCache { $0.invalidate(pid: pid) }
    }

    /// Forgets all cached elements.
    public static func invalidateAll() {
        withCache { $0.invalidateAll() }
    }

    // MARK: Result types

    /// Where an element came from.
    public enum Source: String, Codable, Equatable {
        /// An earlier call, checked again just now.
        case cache
        /// The normal `kAXWindowsAttribute` list.
        case normalList
        /// `_AXUIElementCreateWithRemoteToken` brute force.
        case remoteToken
    }

    /// Why the brute-force part ended (or that it did not run).
    public enum ScanStop: String, Codable, Equatable {
        /// Not started: nothing was missing (or nothing was asked for).
        case notNeeded
        /// Every wanted window id was found.
        case foundAll
        /// All element ids up to the limit were tried.
        case reachedLimit
        /// The time budget ran out.
        case timeBudget
        /// The app did not answer (two timeouts in a row).
        case appNotResponding
        /// The process does not exist.
        case appNotRunning
        /// The private symbol is missing on this macOS version.
        case unavailable
    }

    /// Outcome of one brute-force pass.
    public struct Scan {
        /// Window id -> element.
        public var elements: [UInt32: AXElement] = [:]
        /// Window id -> the element id that produced it.
        public var elementIDs: [UInt32: UInt64] = [:]
        /// How many element ids were tried.
        public var probed = 0
        /// How many of them are real elements of the app (any AX answer except "invalid element"). Mostly
        /// menu bar items and the like; window elements are rare among them.
        public var existing = 0
        public var seconds: TimeInterval = 0
        public var stop: ScanStop = .notNeeded
    }

    /// Outcome of `resolve`: the elements plus how they were found, for tools and logs.
    public struct Resolution {
        /// Window id -> element.
        public var elements: [UInt32: AXElement] = [:]
        public var sources: [UInt32: Source] = [:]
        /// Window id -> element id, for windows found by brute force.
        public var remoteElementIDs: [UInt32: UInt64] = [:]
        /// Entries of the normal AX list that are real windows (role AXWindow with a window id).
        public var normalWindowCount = 0
        /// Entries of the normal AX list that are not usable (placeholders for windows of other Spaces, or
        /// everything while the screen is locked).
        public var placeholderCount = 0
        public var normalSeconds: TimeInterval = 0
        /// Element ids tried by the brute-force pass.
        public var probedElementIDs = 0
        /// How many of the tried ids are real elements of the app.
        public var existingElementIDs = 0
        public var remoteSeconds: TimeInterval = 0
        public var scanStop: ScanStop = .notNeeded
    }

    // MARK: Lookup

    /// Time given to each AX call during a scan. Most ids do not exist and answer at once; this only matters
    /// for an app that hangs.
    private static let scanMessagingTimeout: Float = 0.15

    /// Subroles that count as a window worth managing. Windows without any subrole are accepted too.
    private static let acceptedSubroles: Set<String> = [kAXStandardWindowSubrole, kAXDialogSubrole]

    /// Window id -> element for the windows of `pid`.
    ///
    /// Order of work: cached elements (re-checked) first, then the normal AX list, then brute force through
    /// remote tokens, which only runs when some `wanted` window ids are still missing. With `wanted == nil`
    /// nothing tells when to stop, so the scan runs up to `maxElementID` or `timeBudget`.
    /// The result can hold more windows than were wanted.
    public static func windows(pid: pid_t, wanted: Set<UInt32>? = nil, maxElementID: UInt64 = 1000,
                               timeBudget: TimeInterval = 0.5) -> [UInt32: AXElement] {
        resolve(pid: pid, wanted: wanted, maxElementID: maxElementID, timeBudget: timeBudget).elements
    }

    /// The element of one window of `pid`, or nil when it cannot be found (window gone, screen locked, or the
    /// window's element id is above the default scan limit).
    public static func element(forWindowID windowID: UInt32, pid: pid_t) -> AXElement? {
        windows(pid: pid, wanted: [windowID])[windowID]
    }

    /// Same as `windows(pid:wanted:maxElementID:timeBudget:)` but also reports where each element came from
    /// and how long each step took.
    public static func resolve(pid: pid_t, wanted: Set<UInt32>? = nil, maxElementID: UInt64 = 1000,
                               timeBudget: TimeInterval = 0.5) -> Resolution {
        var result = Resolution()
        if let wanted, wanted.isEmpty { return result }
        guard isRunning(pid) else {
            invalidate(pid: pid)
            result.scanStop = .appNotRunning
            return result
        }

        func isComplete() -> Bool {
            guard let wanted else { return false }
            return wanted.isSubset(of: result.elements.keys)
        }

        // 1. Elements remembered from earlier calls, if they still point at their window.
        let cached = withCache { $0.windows(pid: pid) }
        if !cached.isEmpty {
            var stale: [UInt32] = []
            for (windowID, element) in cached {
                if element.windowID == windowID {
                    result.elements[windowID] = element
                    result.sources[windowID] = .cache
                } else {
                    stale.append(windowID)
                }
            }
            if !stale.isEmpty { withCache { $0.remove(windowIDs: stale, pid: pid) } }
        }
        if isComplete() { return result }

        // 2. The normal list. Anything it holds is as good as the brute-force result, and cheaper.
        let normalStart = monotonicSeconds()
        let listed = AXElement.application(pid: pid).elements(kAXWindowsAttribute)
        var fresh: [UInt32: AXElement] = [:]
        for element in listed {
            guard element.role == kAXWindowRole, let windowID = element.windowID else {
                result.placeholderCount += 1
                continue
            }
            result.normalWindowCount += 1
            fresh[windowID] = element
            // The cached element for the same window is equivalent; the list's own element is the newer one.
            result.elements[windowID] = element
            result.sources[windowID] = .normalList
        }
        result.normalSeconds = monotonicSeconds() - normalStart
        withCache { $0.store(fresh, pid: pid) }
        if isComplete() { return result }

        // 3. Brute force for what is still missing.
        let scan = bruteForce(pid: pid, wanted: wanted.map { $0.subtracting(result.elements.keys) },
                              maxElementID: maxElementID, timeBudget: timeBudget)
        result.probedElementIDs = scan.probed
        result.existingElementIDs = scan.existing
        result.remoteSeconds = scan.seconds
        result.scanStop = scan.stop
        var remote: [UInt32: AXElement] = [:]
        for (windowID, element) in scan.elements where result.sources[windowID] == nil {
            result.elements[windowID] = element
            result.sources[windowID] = .remoteToken
            result.remoteElementIDs[windowID] = scan.elementIDs[windowID]
            remote[windowID] = element
        }
        withCache { $0.store(remote, pid: pid) }
        return result
    }

    /// Only the brute-force pass: tries element ids 0...`maxElementID` of `pid` and keeps the ones that are
    /// windows. No cache, no normal list. `wanted` lets it stop early once those window ids are found
    /// (nil scans everything). Returns the windows found so far when the time budget runs out.
    public static func bruteForce(pid: pid_t, wanted: Set<UInt32>? = nil, maxElementID: UInt64 = 1000,
                                  timeBudget: TimeInterval = 0.5) -> Scan {
        var scan = Scan()
        let start = monotonicSeconds()
        runScan(&scan, pid: pid, wanted: wanted, maxElementID: maxElementID, deadline: start + timeBudget)
        scan.seconds = monotonicSeconds() - start
        return scan
    }

    private static func runScan(_ scan: inout Scan, pid: pid_t, wanted: Set<UInt32>?, maxElementID: UInt64,
                                deadline: TimeInterval) {
        if let wanted, wanted.isEmpty { return }
        guard let create = createWithRemoteToken else {
            scan.stop = .unavailable
            return
        }
        guard isRunning(pid) else {
            scan.stop = .appNotRunning
            return
        }

        var timeoutsInARow = 0
        var elementID: UInt64 = 0
        while true {
            if let wanted, wanted.isSubset(of: scan.elements.keys) {
                scan.stop = .foundAll
                return
            }
            if elementID > maxElementID {
                scan.stop = .reachedLimit
                return
            }
            if monotonicSeconds() >= deadline {
                scan.stop = .timeBudget
                return
            }
            defer { elementID += 1 }

            guard let raw = create(token(pid: pid, elementID: elementID) as CFData)?.takeRetainedValue() else {
                continue
            }
            scan.probed += 1
            let element = AXElement(raw, timeout: scanMessagingTimeout)
            let (role, error) = element.read(kAXRoleAttribute)
            if error != .invalidUIElement { scan.existing += 1 }
            if error == .cannotComplete {
                timeoutsInARow += 1
                if timeoutsInARow >= 2 {
                    scan.stop = .appNotResponding
                    return
                }
                continue
            }
            timeoutsInARow = 0
            guard (role as? String) == kAXWindowRole else { continue }
            if let subrole = element.subrole, !subrole.isEmpty, !acceptedSubroles.contains(subrole) { continue }
            guard let windowID = element.windowID else { continue }

            element.setMessagingTimeout(AXElement.defaultMessagingTimeout)
            if scan.elements[windowID] == nil {
                scan.elements[windowID] = element
                scan.elementIDs[windowID] = elementID
            }
        }
    }

    // MARK: Helpers

    /// True when a process with this pid exists (also when we may not signal it).
    private static func isRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func monotonicSeconds() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
