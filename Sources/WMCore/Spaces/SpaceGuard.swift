import Foundation

// P3.4 Space guard: detects when the Mission Control order of Spaces no longer matches the expected order.
//
// Pure logic lives in `SpaceGuard.evaluate` and the value types here. `DriftWatcher` polls the real order
// through an injected reader, so tests never touch SkyLight. Nothing in this file changes the Space order or
// any system setting: the report only describes the drift and points at the rebuild entry point.

/// One slot of a display's Space order. `key` identifies the Space across reads; `label` is for people.
public struct SpaceSlot: Codable, Equatable, Hashable, Sendable {
    /// "desktop:<n>" (n = Desktop number), "fullscreen:<app>" or "other". A repeated key gets a "#2", "#3" suffix.
    public var key: String
    /// Text for people, such as "Desktop 2" or "Full screen: Safari".
    public var label: String

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

/// The Space order of one display, left to right in Mission Control.
public struct DisplaySpaceOrder: Codable, Equatable, Sendable {
    /// SkyLight display identifier or `DisplayIdentity.uuid`; "Main" for the main display.
    public var displayID: String
    /// Screen name for people, when known.
    public var name: String?
    public var slots: [SpaceSlot]

    public init(displayID: String, name: String?, slots: [SpaceSlot]) {
        self.displayID = displayID
        self.name = name
        self.slots = slots
    }

    /// The live order from `SpaceReader.displays()`.
    public init(displaySpaces display: DisplaySpaces) {
        var bases: [(key: String, label: String)] = []
        for space in display.spaces {
            switch space.kind {
            case .desktop:
                let number = display.desktopNumber(of: space) ?? (bases.count + 1)
                bases.append(("desktop:\(number)", "Desktop \(number)"))
            case .fullscreen:
                let app = space.ownerAppNames.first ?? "unknown app"
                bases.append(("fullscreen:\(app)", "Full screen: \(app)"))
            case .other:
                bases.append(("other", "System Space"))
            }
        }
        self.init(displayID: display.displayIdentifier, name: display.displayName,
                  slots: SpaceGuard.uniqueSlots(bases))
    }

    /// Stored order of one display in a profile. Full-screen Spaces take their app name from the profile's windows.
    public init(profile: Profile, displayUUID: String) {
        let windowApps = Dictionary(profile.windows.map { ($0.id, $0.app.name) }, uniquingKeysWith: { first, _ in first })
        var bases: [(key: String, label: String)] = []
        for space in profile.spaces(onDisplay: displayUUID) {
            switch space.kind {
            case .desktop:
                let number = space.desktopNumber ?? (bases.count + 1)
                bases.append(("desktop:\(number)", "Desktop \(number)"))
            case .fullScreen:
                let app = space.fullScreenWindowIDs.lazy.compactMap { windowApps[$0] }.first ?? "unknown app"
                bases.append(("fullscreen:\(app)", "Full screen: \(app)"))
            case .other:
                bases.append(("other", "System Space"))
            }
        }
        let name = profile.displays.first { $0.uuid == displayUUID }?.name
        self.init(displayID: displayUUID, name: name, slots: SpaceGuard.uniqueSlots(bases))
    }
}

/// How one display's live order differs from the expected order.
public struct DisplaySpaceDrift: Equatable, Sendable {
    public var displayID: String
    public var name: String?
    /// 0-based index of the first slot that is not what was expected (the rebuild starts here).
    public var firstWrongSlot: Int
    /// What the expected order has at `firstWrongSlot`, nil when the expected order is shorter.
    public var expected: SpaceSlot?
    /// What is there now at `firstWrongSlot`, nil when the live order is shorter.
    public var actual: SpaceSlot?
    /// Space keys that are on this display in both orders but at a different index.
    public var movedKeys: [String]
    /// Spaces that are now on the display but were not expected (an extra Desktop or full-screen Space).
    public var extraKeys: [String]
    /// Expected Spaces that are gone from the display.
    public var missingKeys: [String]

    public init(displayID: String, name: String?, firstWrongSlot: Int, expected: SpaceSlot?, actual: SpaceSlot?,
                movedKeys: [String], extraKeys: [String], missingKeys: [String]) {
        self.displayID = displayID
        self.name = name
        self.firstWrongSlot = firstWrongSlot
        self.expected = expected
        self.actual = actual
        self.movedKeys = movedKeys
        self.extraKeys = extraKeys
        self.missingKeys = missingKeys
    }

    public var summary: String {
        let screen = name ?? displayID
        var text = "\(screen): slot \(firstWrongSlot + 1) is "
        text += actual.map { "\($0.label)" } ?? "empty"
        text += ", expected " + (expected.map { "\($0.label)" } ?? "nothing")
        if !extraKeys.isEmpty { text += ". Extra Space: \(extraKeys.count)" }
        if !missingKeys.isEmpty { text += ". Missing Space: \(missingKeys.count)" }
        if !movedKeys.isEmpty { text += ". Moved: \(movedKeys.count)" }
        return text + "."
    }
}

/// Where a rebuild of the order should start. It describes the plan; nothing is changed by building it.
public struct SpaceFixPlan: Equatable, Sendable {
    public var displayID: String
    /// Slot to rebuild from (0-based): every slot from here on is written in the expected order.
    public var fromSlot: Int
    public var description: String

    public init(displayID: String, fromSlot: Int, description: String) {
        self.displayID = displayID
        self.fromSlot = fromSlot
        self.description = description
    }
}

public struct SpaceGuardReport: Equatable, Sendable {
    /// Displays whose order differs from the expected order, in expected order.
    public var drifts: [DisplaySpaceDrift]
    /// Displays in the expected order that are not connected now. A rebuild cannot fix these.
    public var missingDisplayIDs: [String]
    /// Set when "Automatically rearrange Spaces based on most recent use" is on (or not set, which macOS treats as on).
    public var mruSpacesWarning: String?
    /// The first wrong slot of the first drifted display; nil when clean or when only missing displays differ.
    public var fixPlan: SpaceFixPlan?

    public init(drifts: [DisplaySpaceDrift], missingDisplayIDs: [String], mruSpacesWarning: String?, fixPlan: SpaceFixPlan?) {
        self.drifts = drifts
        self.missingDisplayIDs = missingDisplayIDs
        self.mruSpacesWarning = mruSpacesWarning
        self.fixPlan = fixPlan
    }

    /// True when every expected display is present and in the expected order. The mru warning does not count.
    public var isClean: Bool { drifts.isEmpty && missingDisplayIDs.isEmpty }

    /// Identifies this drift so the watcher can report each new drift once.
    public var fingerprint: String {
        let parts = drifts.map { drift in
            [drift.displayID, String(drift.firstWrongSlot), drift.movedKeys.joined(separator: ","),
             drift.extraKeys.joined(separator: ","), drift.missingKeys.joined(separator: ","),
             drift.actual?.key ?? "-"].joined(separator: "|")
        }
        return (parts + missingDisplayIDs.map { "missing|" + $0 }).joined(separator: "\n")
    }
}

/// Settings for the Space guard, stored as JSON by the app.
public struct SpaceGuardSettings: Codable, Equatable, Sendable {
    /// Poll the Space order and report drift.
    public var watchEnabled: Bool
    /// When drift is confirmed, ask for a fix. The fix itself is not automatic yet (see `SpaceGuardController.fix`).
    public var autoFix: Bool
    /// The order the user wants. Nil until a profile is captured or "Set current order as expected" is used.
    public var expectedOrder: [DisplaySpaceOrder]?
    /// Where `expectedOrder` came from, for people: "Profile Home" or "Current order".
    public var expectedSource: String?

    public init(watchEnabled: Bool = false, autoFix: Bool = false, expectedOrder: [DisplaySpaceOrder]? = nil,
                expectedSource: String? = nil) {
        self.watchEnabled = watchEnabled
        self.autoFix = autoFix
        self.expectedOrder = expectedOrder
        self.expectedSource = expectedSource
    }

    private enum CodingKeys: String, CodingKey { case watchEnabled, autoFix, expectedOrder, expectedSource }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        watchEnabled = try c.decodeIfPresent(Bool.self, forKey: .watchEnabled) ?? false
        autoFix = try c.decodeIfPresent(Bool.self, forKey: .autoFix) ?? false
        expectedOrder = try c.decodeIfPresent([DisplaySpaceOrder].self, forKey: .expectedOrder)
        expectedSource = try c.decodeIfPresent(String.self, forKey: .expectedSource)
    }

    public var hasExpectedOrder: Bool { !(expectedOrder ?? []).isEmpty }

    /// Stores `order` as the expected order, for example from a captured profile or the current Spaces.
    public mutating func setExpected(_ order: [DisplaySpaceOrder], source: String) {
        expectedOrder = order
        expectedSource = source
    }
}

public enum SpaceGuard {
    /// Compares the live order with the expected order and builds the report. Pure: no system calls.
    /// Displays that are only live (not expected) are ignored. An empty expected order is always clean.
    public static func evaluate(expected: [DisplaySpaceOrder], actual: [DisplaySpaceOrder],
                                mruSpaces: Bool?) -> SpaceGuardReport {
        var drifts: [DisplaySpaceDrift] = []
        var missing: [String] = []
        for wanted in expected {
            guard let live = actual.first(where: { $0.displayID == wanted.displayID }) else {
                missing.append(wanted.displayID)
                continue
            }
            if let drift = drift(expected: wanted, actual: live) { drifts.append(drift) }
        }

        var fixPlan: SpaceFixPlan?
        if let first = drifts.first {
            fixPlan = SpaceFixPlan(
                displayID: first.displayID,
                fromSlot: first.firstWrongSlot,
                description: "Rebuild \(first.name ?? first.displayID) from slot \(first.firstWrongSlot + 1)"
                    + " (expected \(first.expected?.label ?? "nothing")). Every slot from there on is written"
                    + " in the expected order. Run `spaceslab order-file apply` (SpaceOrderFile.reordered with"
                    + " performApply in OrderFileCommand) yourself; the app does not rebuild by itself."
            )
        }

        return SpaceGuardReport(drifts: drifts, missingDisplayIDs: missing,
                                mruSpacesWarning: mruWarning(mruSpaces), fixPlan: fixPlan)
    }

    /// The drift of one display, or nil when its order matches.
    static func drift(expected: DisplaySpaceOrder, actual: DisplaySpaceOrder) -> DisplaySpaceDrift? {
        let want = expected.slots.map(\.key)
        let have = actual.slots.map(\.key)
        guard want != have else { return nil }

        // The first slot that differs, counting a missing slot (one list shorter) as different.
        let firstWrong = (0..<max(want.count, have.count)).first { index in
            index >= want.count || index >= have.count || want[index] != have[index]
        } ?? 0

        let wantSet = Set(want)
        let haveSet = Set(have)
        let wantIndex = Dictionary(want.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let haveIndex = Dictionary(have.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let moved = want.filter { key in
            guard haveSet.contains(key), let a = wantIndex[key], let b = haveIndex[key] else { return false }
            return a != b
        }
        let extra = have.filter { !wantSet.contains($0) }
        let missing = want.filter { !haveSet.contains($0) }

        return DisplaySpaceDrift(
            displayID: expected.displayID,
            name: actual.name ?? expected.name,
            firstWrongSlot: firstWrong,
            expected: firstWrong < expected.slots.count ? expected.slots[firstWrong] : nil,
            actual: firstWrong < actual.slots.count ? actual.slots[firstWrong] : nil,
            movedKeys: moved,
            extraKeys: extra,
            missingKeys: missing
        )
    }

    /// Warning text when macOS may reorder Spaces by itself. nil (not set) means macOS uses its default, which is on.
    public static func mruWarning(_ mruSpaces: Bool?) -> String? {
        guard mruSpaces != false else { return nil }
        let state = mruSpaces == nil ? "is not set, so macOS uses its default (on)" : "is on"
        return "\"Automatically rearrange Spaces based on most recent use\" \(state). macOS can reorder Spaces by itself, "
            + "so the order will keep drifting. Turn it off in System Settings > Desktop & Dock. "
            + "Windows Manager never changes this setting."
    }

    /// Gives every slot a unique key: a repeated base key gets "#2", "#3", ...
    static func uniqueSlots(_ bases: [(key: String, label: String)]) -> [SpaceSlot] {
        var seen: [String: Int] = [:]
        return bases.map { base in
            let count = (seen[base.key] ?? 0) + 1
            seen[base.key] = count
            return SpaceSlot(key: count == 1 ? base.key : "\(base.key)#\(count)", label: base.label)
        }
    }
}

/// Polls the real Space order every `interval` seconds and reports each new drift once.
/// A drift must show up on `confirmations` polls in a row before it is reported (debounce), so a Space
/// that is still moving during a Mission Control animation does not fire.
public final class DriftWatcher {
    public typealias Reader = () throws -> [DisplaySpaceOrder]

    public let interval: TimeInterval
    public let confirmations: Int
    /// Expected order to compare with. Set by the app when the settings change.
    public var expected: [DisplaySpaceOrder]
    public private(set) var lastReport: SpaceGuardReport?
    public private(set) var lastChecked: Date?
    public private(set) var lastError: String?

    private let reader: Reader
    private let mruSpaces: () -> Bool?
    private let clock: () -> Date
    private let onDrift: (SpaceGuardReport) -> Void
    private var pendingFingerprint: String?
    private var pendingPolls = 0
    private var reportedFingerprint: String?
    private var timer: Timer?

    public init(expected: [DisplaySpaceOrder] = [], interval: TimeInterval = 10, confirmations: Int = 2,
                reader: @escaping Reader = DriftWatcher.liveReader,
                mruSpaces: @escaping () -> Bool? = DriftWatcher.liveMruSpaces,
                clock: @escaping () -> Date = { Date() },
                onDrift: @escaping (SpaceGuardReport) -> Void) {
        self.expected = expected
        self.interval = interval
        self.confirmations = max(1, confirmations)
        self.reader = reader
        self.mruSpaces = mruSpaces
        self.clock = clock
        self.onDrift = onDrift
    }

    /// Reads the order once, evaluates it and fires `onDrift` when a confirmed, new drift is seen.
    /// Returns the report, or nil when the reader failed.
    @discardableResult
    public func poll() -> SpaceGuardReport? {
        let actual: [DisplaySpaceOrder]
        do {
            actual = try reader()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        let report = SpaceGuard.evaluate(expected: expected, actual: actual, mruSpaces: mruSpaces())
        lastReport = report
        lastChecked = clock()

        guard !report.isClean else {
            pendingFingerprint = nil
            pendingPolls = 0
            reportedFingerprint = nil
            return report
        }

        let fingerprint = report.fingerprint
        if fingerprint == pendingFingerprint {
            pendingPolls += 1
        } else {
            pendingFingerprint = fingerprint
            pendingPolls = 1
        }
        if pendingPolls >= confirmations && fingerprint != reportedFingerprint {
            reportedFingerprint = fingerprint
            onDrift(report)
        }
        return report
    }

    /// Starts polling on the main run loop. Call from the main thread.
    public func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public var isRunning: Bool { timer != nil }

    /// Real order from SkyLight through `SpaceReader`.
    public static func liveReader() throws -> [DisplaySpaceOrder] {
        try SpaceReader.displays().map(DisplaySpaceOrder.init(displaySpaces:))
    }

    /// The Dock's "mru-spaces" value; nil when the key is not set.
    public static func liveMruSpaces() -> Bool? {
        UserDefaults(suiteName: "com.apple.dock")?.object(forKey: "mru-spaces") as? Bool
    }
}
