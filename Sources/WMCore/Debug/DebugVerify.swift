import CoreGraphics
import Foundation

// Pure verify logic for the live challenge tests (P6.70). No real windows are read here: the runner converts what
// it scanned into `DebugLiveWindow` values and this file decides pass or fail, so it is unit tested.

public enum DebugScenarioID: String, CaseIterable, Sendable {
    case s1Cold, s2WrongPlace, s3Mixed, s4Extras, s7Rerun, home

    public var title: String {
        switch self {
        case .s1Cold: return "S1 Cold start"
        case .s2WrongPlace: return "S2 Wrong place"
        case .s3Mixed: return "S3 Mixed states"
        case .s4Extras: return "S4 Extras untouched"
        case .s7Rerun: return "S7 Re-run is a no-op"
        case .home: return "Home profile"
        }
    }

    public var summary: String {
        switch self {
        case .s1Cold: return "Fixture apps quit, then restore: expect launches and one add-desktop."
        case .s2WrongPlace: return "All apps open on D1, shifted 200 pt and half size, then restore."
        case .s3Mixed: return "Notes minimized, TextEdit full screen, Calculator hidden, Finder without a window."
        case .s4Extras: return "An extra TextEdit window that is not in the profile must stay where it is."
        case .s7Rerun: return "Restore twice: the second run does no moves and no launches."
        case .home: return "Home profile: Finder and Notes split, Safari maximized, Calculator on all desktops."
        }
    }
}

public enum DebugStepStatus: String, Sendable { case pending, running, done, skipped, failed }

public struct DebugStepRow: Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var target: String
    public var status: DebugStepStatus
    public var detail: String

    public init(id: String, kind: String, target: String, status: DebugStepStatus, detail: String = "") {
        self.id = id
        self.kind = kind
        self.target = target
        self.status = status
        self.detail = detail
    }
}

public struct DebugCheck: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var passed: Bool
    public var detail: String

    public init(id: String, name: String, passed: Bool, detail: String) {
        self.id = id
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

public enum DebugEvent: Sendable {
    case phase(String)
    case step(DebugStepRow)
    case check(DebugCheck)
    case log(String)
}

public struct DebugRunResult: Sendable {
    public var scenario: DebugScenarioID
    public var passed: Bool
    public var checks: [DebugCheck]
    public var log: [String]

    public init(scenario: DebugScenarioID, passed: Bool, checks: [DebugCheck], log: [String]) {
        self.scenario = scenario
        self.passed = passed
        self.checks = checks
        self.log = log
    }
}

/// A live window reduced to what the checks need.
public struct DebugLiveWindow: Equatable, Sendable {
    public var windowID: UInt32
    public var bundleID: String?
    public var title: String?
    public var frame: CGRect
    /// 1-based Desktop number on its display; nil when unknown or on all desktops.
    public var desktop: Int?
    public var isMinimized: Bool
    public var isFullScreen: Bool
    public var isAppHidden: Bool
    /// Stage Manager parked this window in the strip or another stage: the engine leaves such windows alone by design.
    public var isInStageStrip: Bool

    public init(windowID: UInt32, bundleID: String?, title: String? = nil, frame: CGRect, desktop: Int? = nil,
                isMinimized: Bool = false, isFullScreen: Bool = false, isAppHidden: Bool = false,
                isInStageStrip: Bool = false) {
        self.isInStageStrip = isInStageStrip
        self.windowID = windowID
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.desktop = desktop
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
        self.isAppHidden = isAppHidden
    }
}

/// What one saved window must look like after the restore.
public struct DebugExpectation: Equatable, Sendable {
    public var label: String
    public var bundleID: String
    public var frame: CGRect
    public var desktop: Int?
    public var isMinimized = false
    public var isFullScreen = false

    public init(label: String, bundleID: String, frame: CGRect, desktop: Int? = nil,
                isMinimized: Bool = false, isFullScreen: Bool = false) {
        self.label = label
        self.bundleID = bundleID
        self.frame = frame
        self.desktop = desktop
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
    }
}

/// A window that is not in the profile and must not change.
public struct DebugExtra: Equatable, Sendable {
    public var windowID: UInt32
    public var label: String
    public var frame: CGRect
    public var desktop: Int?

    public init(windowID: UInt32, label: String, frame: CGRect, desktop: Int?) {
        self.windowID = windowID
        self.label = label
        self.frame = frame
        self.desktop = desktop
    }
}

public enum DebugVerify {
    /// Position and size tolerance in points.
    public static let tolerance: CGFloat = 4

    public static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = DebugVerify.tolerance) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// The window kept the wanted origin but is smaller than asked: the app's minimum size (not a failure).
    public static func isClamped(actual: CGRect, wanted: CGRect, tolerance: CGFloat = DebugVerify.tolerance) -> Bool {
        abs(actual.minX - wanted.minX) <= tolerance && abs(actual.minY - wanted.minY) <= tolerance
            && (actual.width > wanted.width + tolerance || actual.height > wanted.height + tolerance)
    }

    /// Sum of the four edge differences, used to pair windows with expectations.
    public static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// One result per assertion. Windows are paired greedily: each expectation takes the nearest unused live
    /// window of the same app, so two same-titled windows are never swapped.
    public static func evaluate(expectations: [DebugExpectation], live: [DebugLiveWindow],
                                extras: [DebugExtra] = [], desktopCount: Int? = nil,
                                stageManagerOn: Bool = false) -> [DebugCheck] {
        var checks: [DebugCheck] = []
        var used = Set<UInt32>()
        for (i, e) in expectations.enumerated() {
            let key = "w\(i)-\(e.label)"
            let candidates = live.filter { $0.bundleID == e.bundleID && !used.contains($0.windowID) }
            guard let w = candidates.min(by: { distance($0.frame, e.frame) < distance($1.frame, e.frame) }) else {
                checks.append(DebugCheck(id: key + "-present", name: "\(e.label): window present",
                                         passed: stageManagerOn,
                                         detail: stageManagerOn
                                             ? "INCONCLUSIVE: Stage Manager is on and the window may sit in another stage"
                                             : "no live window of \(e.bundleID)"))
                continue
            }
            used.insert(w.windowID)
            let parked = stageManagerOn && w.isInStageStrip
            let near = candidates.filter { framesMatch($0.frame, e.frame) }.count
            checks.append(DebugCheck(id: key + "-present", name: "\(e.label): window present", passed: true,
                                     detail: "window \(w.windowID)" + (near > 1 ? ", \(near) windows on the frame" : "")))
            if e.isFullScreen {
                checks.append(DebugCheck(id: key + "-fs", name: "\(e.label): full screen", passed: w.isFullScreen,
                                         detail: "isFullScreen=\(w.isFullScreen)"))
            } else {
                let ok = framesMatch(w.frame, e.frame) || parked
                let clamped = !ok && isClamped(actual: w.frame, wanted: e.frame)
                checks.append(DebugCheck(
                    id: key + "-frame", name: "\(e.label): on target frame", passed: ok || clamped,
                    detail: parked ? "INCONCLUSIVE: window is in the Stage Manager strip" : ok ? "within \(Int(tolerance)) pt" : (clamped ? "clamped to minimum size \(describe(w.frame))"
                                                                  : "is \(describe(w.frame)), want \(describe(e.frame))")))
                checks.append(DebugCheck(id: key + "-fsoff", name: "\(e.label): not full screen",
                                         passed: !w.isFullScreen, detail: "isFullScreen=\(w.isFullScreen)"))
            }
            checks.append(DebugCheck(id: key + "-min", name: "\(e.label): minimized state",
                                     passed: w.isMinimized == e.isMinimized, detail: "isMinimized=\(w.isMinimized)"))
            checks.append(DebugCheck(id: key + "-hidden", name: "\(e.label): not hidden", passed: !w.isAppHidden,
                                     detail: "isAppHidden=\(w.isAppHidden)"))
            if let want = e.desktop, let count = desktopCount, want > count {
                checks.append(DebugCheck(id: key + "-desktop", name: "\(e.label): on desktop \(want)", passed: true,
                                         detail: "INCONCLUSIVE: only \(count) Desktop(s) exist and this Mac would not add one; window is on desktop \(w.desktop.map(String.init) ?? "?")"))
            } else if let want = e.desktop {
                let inconclusive = parked && w.desktop != want
                checks.append(DebugCheck(id: key + "-desktop", name: "\(e.label): on desktop \(want)",
                                         passed: w.desktop == want || inconclusive,
                                         detail: inconclusive ? "INCONCLUSIVE: window is in the Stage Manager strip, desktop=\(w.desktop.map(String.init) ?? "?")"
                                             : "desktop=\(w.desktop.map(String.init) ?? "?")"))
            }
        }
        for x in extras {
            guard let w = live.first(where: { $0.windowID == x.windowID }) else {
                checks.append(DebugCheck(id: "extra-\(x.windowID)", name: "extra \(x.label): untouched", passed: false,
                                         detail: "window is gone"))
                continue
            }
            let frameOK = framesMatch(w.frame, x.frame)
            let spaceOK = x.desktop == nil || w.desktop == x.desktop
            checks.append(DebugCheck(id: "extra-\(x.windowID)", name: "extra \(x.label): untouched",
                                     passed: frameOK && spaceOK,
                                     detail: frameOK && spaceOK ? "same frame and desktop"
                                         : "now \(describe(w.frame)) desktop \(w.desktop.map(String.init) ?? "?"), was \(describe(x.frame))"))
        }
        return checks
    }

    public static func describe(_ r: CGRect) -> String {
        "\(Int(r.minX.rounded())),\(Int(r.minY.rounded())) \(Int(r.width.rounded()))x\(Int(r.height.rounded()))"
    }
}
