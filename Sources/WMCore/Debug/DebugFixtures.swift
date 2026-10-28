import AppKit
import CoreGraphics
import Foundation

// Power-user challenge fixtures (P6.116). Pure builders: nothing here reads or moves live windows.
// Every scenario is a `Profile` made from stock Mac apps. Geometry is written in a reference frame of
// 2560 x 1415 (a 2560 x 1440 display minus a 25 pt menu bar) and scaled onto the real visible frame of
// each display, so the same builders work on any monitor. The menu bar offset follows the existing
// fixtures in DebugTestRunner: a window at the top of a display starts at `visibleFrame.minY`.

/// Static description of one power-user scenario, used by the runner, the debug panel and `--list`.
public struct DebugScenarioSpec: Hashable, Sendable, Identifiable {
    /// Stable id, also the value of `wm debug run --scenario`.
    public let id: String
    public let title: String
    public let summary: String
    /// Bundle ids that must be installed; a missing one marks the scenario SKIPPED.
    public let requiredBundleIDs: [String]
    /// Highest 1-based Desktop number the scenario uses on any display.
    public let requiredDesktops: Int
    /// Monitors the scenario needs; fewer makes the run INCONCLUSIVE.
    public let requiredDisplays: Int
    /// Bundle ids whose saved size the app is expected to refuse (the step ends "done (size limited)").
    public let expectsSizeLimited: [String]
    /// True when a second run of the same profile must plan zero steps.
    public let expectsIdempotent: Bool

    public init(id: String, title: String, summary: String, requiredBundleIDs: [String], requiredDesktops: Int,
                requiredDisplays: Int, expectsSizeLimited: [String] = [], expectsIdempotent: Bool = false) {
        self.id = id
        self.title = title
        self.summary = summary
        self.requiredBundleIDs = requiredBundleIDs
        self.requiredDesktops = requiredDesktops
        self.requiredDisplays = requiredDisplays
        self.expectsSizeLimited = expectsSizeLimited
        self.expectsIdempotent = expectsIdempotent
    }
}

public enum DebugFixtures {
    // Stock apps used by the scenarios.
    public static let textEdit = "com.apple.TextEdit"
    public static let terminal = "com.apple.Terminal"
    public static let safari = "com.apple.Safari"
    public static let preview = "com.apple.Preview"
    public static let notes = "com.apple.Notes"
    public static let reminders = "com.apple.reminders"
    public static let faceTime = "com.apple.FaceTime"
    public static let calculator = "com.apple.calculator"
    public static let systemSettings = "com.apple.systempreferences"
    public static let finder = "com.apple.finder"
    public static let music = "com.apple.Music"
    public static let activityMonitor = "com.apple.ActivityMonitor"

    /// Every bundle id any scenario uses, sorted.
    public static var allBundleIDs: [String] {
        Array(Set(scenarios.flatMap(\.requiredBundleIDs))).sorted()
    }

    /// Reference visible size the builders design against (2560 x 1440 minus the 25 pt menu bar).
    static let referenceWidth: CGFloat = 2560
    static let referenceHeight: CGFloat = 1415
    static let menuBarHeight: CGFloat = 25

    /// Prefix of every fixture profile name, so the runner can find and replace them.
    public static let namePrefix = "Challenge "

    // MARK: Scenario metadata

    public static let scenarios: [DebugScenarioSpec] = [
        DebugScenarioSpec(id: "deep-work", title: "Deep work",
                          summary: "TextEdit, Terminal and Safari in thirds on display 1; Preview bottom half on display 2.",
                          requiredBundleIDs: [textEdit, terminal, safari, preview],
                          requiredDesktops: 1, requiredDisplays: 2),
        DebugScenarioSpec(id: "meetings", title: "Meetings",
                          summary: "FaceTime right third and Notes (minimized) left two thirds on display 2; Reminders on display 1.",
                          requiredBundleIDs: [faceTime, notes, reminders],
                          requiredDesktops: 1, requiredDisplays: 2),
        DebugScenarioSpec(id: "vpn-tools", title: "VPN tools",
                          summary: "Calculator (fixed size), System Settings (fixed width 740) and an About panel at an impossible size.",
                          requiredBundleIDs: [calculator, systemSettings],
                          requiredDesktops: 1, requiredDisplays: 1,
                          expectsSizeLimited: [calculator, systemSettings], expectsIdempotent: true),
        DebugScenarioSpec(id: "design-2mon", title: "Design, two monitors",
                          summary: "Huge Preview window and windows at negative coordinates; pulled on screen when one display is left.",
                          requiredBundleIDs: [preview, finder, notes, textEdit],
                          requiredDesktops: 1, requiredDisplays: 2),
        DebugScenarioSpec(id: "home-work-work", title: "Home-work: apply Work",
                          summary: "Apply Work while Home windows are open; Home-only windows stay untouched.",
                          requiredBundleIDs: [textEdit, calculator, notes, finder, safari],
                          requiredDesktops: 3, requiredDisplays: 1),
        DebugScenarioSpec(id: "home-work-home", title: "Home-work: apply Home",
                          summary: "Apply Home while Work windows are open; Calculator on All Desktops stays.",
                          requiredBundleIDs: [finder, notes, safari, calculator],
                          requiredDesktops: 2, requiredDisplays: 1),
        DebugScenarioSpec(id: "partial", title: "Partial (display 2 only)",
                          summary: "Only display 2 is in the profile; display 1 must stay byte-identical.",
                          requiredBundleIDs: [notes, safari],
                          requiredDesktops: 2, requiredDisplays: 2),
        DebugScenarioSpec(id: "mixed-states", title: "Mixed window states",
                          summary: "A minimized Notes window, a full-screen Safari Space and a Preview window to cold launch.",
                          requiredBundleIDs: [textEdit, notes, preview, safari],
                          requiredDesktops: 2, requiredDisplays: 1),
        DebugScenarioSpec(id: "dupes", title: "Duplicates",
                          summary: "Three Untitled TextEdit windows and two Finder windows on the same folder; no swaps.",
                          requiredBundleIDs: [textEdit, finder],
                          requiredDesktops: 1, requiredDisplays: 1),
        DebugScenarioSpec(id: "slow-front", title: "Slow cold launch, front window",
                          summary: "Cold Music and Activity Monitor while Terminal is frontmost; focus must end on Terminal.",
                          requiredBundleIDs: [terminal, music, activityMonitor],
                          requiredDesktops: 1, requiredDisplays: 1),
        DebugScenarioSpec(id: "twice-minsize", title: "Saved size below minimum",
                          summary: "TextEdit saved at 120 x 80, below its minimum; the second run must plan zero steps.",
                          requiredBundleIDs: [textEdit, safari],
                          requiredDesktops: 1, requiredDisplays: 1,
                          expectsSizeLimited: [textEdit], expectsIdempotent: true),
    ]

    /// The spec for one scenario id, or nil for an unknown id.
    public static func spec(id: String) -> DebugScenarioSpec? {
        scenarios.first { $0.id == id }
    }

    /// The bundle ids among `candidates` that NSWorkspace can resolve to an installed app.
    public static func availableBundleIDs(_ candidates: [String] = allBundleIDs) -> Set<String> {
        Set(candidates.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
    }

    /// True when a required app is missing, so the scenario is reported SKIPPED instead of run.
    public static func isSkipped(_ spec: DebugScenarioSpec, installed: Set<String>) -> Bool {
        !Set(spec.requiredBundleIDs).isSubset(of: installed)
    }

    // MARK: Profiles

    /// Every scenario with its profile, built on `displays` (default: synthetic 2560 x 1440 monitors, two of them).
    public static func profiles(displays: [DisplayIdentity]? = nil) -> [(spec: DebugScenarioSpec, profile: Profile)] {
        let displays = displays ?? syntheticDisplays(count: 2)
        return scenarios.compactMap { spec in
            guard let profile = profile(for: spec.id, displays: displays) else { return nil }
            return (spec, profile)
        }
    }

    /// The profile for one scenario id, or nil for an unknown id.
    public static func profile(for id: String, displays: [DisplayIdentity]? = nil) -> Profile? {
        guard let spec = spec(id: id) else { return nil }
        let displays = displays ?? syntheticDisplays(count: max(1, spec.requiredDisplays))
        guard !displays.isEmpty else { return nil }
        var b = Builder(displays: displays)
        switch id {
        case "deep-work":
            b.desktops(1, on: 0)
            b.desktops(1, on: 1)
            b.add(textEdit, "TextEdit", b.frame(0, 0, 0, 853, 1415), on: 0, desktop: 1, z: 1)
            b.add(terminal, "Terminal", b.frame(0, 853, 0, 853, 1415), on: 0, desktop: 1, z: 2)
            b.add(safari, "Safari", b.frame(0, 1706, 0, 854, 1415), on: 0, desktop: 1, z: 3)
            b.add(preview, "Preview", b.frame(1, 0, 707, 2560, 708), on: 1, desktop: 1, z: 4)
        case "meetings":
            b.desktops(1, on: 0)
            b.desktops(1, on: 1)
            b.add(reminders, "Reminders", b.frame(0, 1280, 0, 1280, 1415), on: 0, desktop: 1, z: 3)
            b.add(notes, "Notes", b.frame(1, 0, 0, 1706, 1415), on: 1, desktop: 1, z: 2, minimized: true)
            b.add(faceTime, "FaceTime", b.frame(1, 1706, 0, 854, 1415), on: 1, desktop: 1, z: 1)
        case "vpn-tools":
            b.desktops(1, on: 0)
            b.add(calculator, "Calculator", b.frame(0, 2330, 0, 230, 408), on: 0, desktop: 1, z: 1)
            b.add(systemSettings, "System Settings", b.frame(0, 100, 100, 740, 600), on: 0, desktop: 1, z: 2)
            b.add(systemSettings, "System Settings", b.frame(0, 200, 200, 960, 1015), on: 0, desktop: 1, z: 3,
                  title: "About This Mac", match: .contains("About"), index: 1)
        case "design-2mon":
            b.desktops(1, on: 0)
            b.desktops(1, on: 1)
            b.add(preview, "Preview", b.frame(0, 0, 0, 1800, 1100), on: 0, desktop: 1, z: 1)
            // Deliberately off-screen: negative coordinates, pulled on screen when one display is left.
            b.add(finder, "Finder", CGRect(x: -1400, y: 300, width: 700, height: 500), on: 1, desktop: 1, z: 2)
            b.add(notes, "Notes", b.frame(1, 100, 100, 1000, 700), on: 1, desktop: 1, z: 3)
            b.add(textEdit, "TextEdit", CGRect(x: 400, y: -300, width: 600, height: 400), on: 0, desktop: 1, z: 4)
        case "home-work-work":
            b.desktops(3, on: 0)
            b.add(textEdit, "TextEdit", b.frame(0, 0, 0, 853, 1415), on: 0, desktop: 1, z: 1)
            b.add(calculator, "Calculator", b.frame(0, 2330, 0, 230, 408), on: 0, desktop: nil, z: 6)
            b.add(notes, "Notes", b.frame(0, 100, 100, 1000, 700), on: 0, desktop: 2, z: 2)
            b.add(finder, "Finder", b.frame(0, 900, 400, 700, 500), on: 0, desktop: 2, z: 3)
            b.add(safari, "Safari", b.frame(0, 0, 0, 1200, 800), on: 0, desktop: 3, z: 4)
            b.add(textEdit, "TextEdit", b.frame(0, 1250, 0, 600, 500), on: 0, desktop: 3, z: 5, index: 1)
        case "home-work-home":
            b.desktops(2, on: 0)
            b.add(finder, "Finder", b.frame(0, 0, 0, 1280, 1415), on: 0, desktop: 1, z: 2)
            b.add(notes, "Notes", b.frame(0, 1280, 0, 1280, 1415), on: 0, desktop: 1, z: 3)
            b.add(safari, "Safari", b.frame(0, 0, 0, 2560, 1415), on: 0, desktop: 2, z: 1)
            b.add(calculator, "Calculator", b.frame(0, 2330, 40, 230, 408), on: 0, desktop: nil, z: 4)
        case "partial":
            b.desktops(2, on: 1)
            b.add(notes, "Notes", b.frame(1, 100, 100, 1000, 700), on: 1, desktop: 1, z: 2)
            b.add(safari, "Safari", b.frame(1, 0, 0, 2560, 1415), on: 1, desktop: 2, z: 1)
        case "mixed-states":
            b.desktops(2, on: 0)
            b.add(textEdit, "TextEdit", b.frame(0, 0, 0, 1280, 1415), on: 0, desktop: 1, z: 2)
            b.add(notes, "Notes", b.frame(0, 1280, 0, 1280, 1415), on: 0, desktop: 1, z: 3, minimized: true)
            b.add(preview, "Preview", b.frame(0, 200, 200, 900, 700), on: 0, desktop: 2, z: 4)
            b.addFullScreen(safari, "Safari", CGRect(x: displays[0].frame.minX, y: displays[0].frame.minY,
                                                     width: displays[0].frame.width, height: displays[0].frame.height),
                            on: 0, position: 2, z: 1)
        case "dupes":
            b.desktops(1, on: 0)
            for i in 0..<3 {
                b.add(textEdit, "TextEdit", b.frame(0, CGFloat(i) * 700, 0, 600, 500), on: 0, desktop: 1, z: i + 1,
                      title: "Untitled", match: .exact("Untitled"), index: i)
            }
            for i in 0..<2 {
                b.add(finder, "Finder", b.frame(0, CGFloat(i) * 900, 600 + CGFloat(i) * 60, 600, 500), on: 0, desktop: 1,
                      z: 4 + i, title: "Fixtures", match: .exact("Fixtures"), index: i,
                      documentPath: "file:///Users/debug/Fixtures/")
            }
        case "slow-front":
            b.desktops(1, on: 0)
            b.add(terminal, "Terminal", b.frame(0, 0, 0, 853, 1415), on: 0, desktop: 1, z: 0)
            b.add(music, "Music", b.frame(0, 853, 0, 1707, 800), on: 0, desktop: 1, z: 1)
            b.add(activityMonitor, "Activity Monitor", b.frame(0, 853, 800, 1707, 615), on: 0, desktop: 1, z: 2)
        case "twice-minsize":
            b.desktops(1, on: 0)
            b.add(textEdit, "TextEdit", CGRect(x: displays[0].visibleFrame.minX, y: displays[0].visibleFrame.minY,
                                               width: 120, height: 80), on: 0, desktop: 1, z: 2)
            b.add(safari, "Safari", b.frame(0, 200, 100, 1280, 900), on: 0, desktop: 1, z: 1)
        default:
            return nil
        }
        // A fixed date keeps the builders deterministic and the JSON round trip exact (ISO-8601 drops sub-seconds).
        return Profile(name: namePrefix + spec.title, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                       monitorSetKey: DisplayMap.monitorSetKey(displays), displays: displays,
                       spaces: b.spaces, windows: b.windows)
    }

    // MARK: Store

    /// Saves every scenario profile into `store`, replacing an installed profile with the same name (same id).
    @discardableResult
    public static func installPowerUserFixtures(into store: ProfileStore,
                                                displays: [DisplayIdentity]? = nil) throws -> [Profile] {
        let live = displays ?? liveDisplays()
        let existing = store.list()
        var saved: [Profile] = []
        for (_, var p) in profiles(displays: live) {
            if let old = existing.first(where: { $0.name == p.name }) { p.id = old.id }
            saved.append(try store.save(p))
        }
        return saved
    }

    /// The monitors attached now, or synthetic ones when none can be read.
    static func liveDisplays() -> [DisplayIdentity] {
        let current = DisplayMap.current()
        return current.isEmpty ? syntheticDisplays(count: 2) : current
    }

    /// Two or fewer synthetic 2560 x 1440 monitors side by side, with a 25 pt menu bar on each.
    public static func syntheticDisplays(count: Int) -> [DisplayIdentity] {
        (0..<max(1, count)).map { i in
            let frame = CGRect(x: CGFloat(i) * 2560, y: 0, width: 2560, height: 1440)
            let visible = CGRect(x: frame.minX, y: menuBarHeight, width: 2560, height: referenceHeight)
            return DisplayIdentity(uuid: "DEBUG-FIXTURE-DISPLAY-\(i + 1)", name: "Fixture display \(i + 1)",
                                   frame: frame, visibleFrame: visible, isMain: i == 0, isBuiltIn: false)
        }
    }
}

// MARK: - Builder

/// Accumulates the windows and Spaces of one fixture profile.
private struct Builder {
    let displays: [DisplayIdentity]
    var windows: [WindowSnapshot] = []
    var spaces: [SpaceSnapshot] = []

    init(displays: [DisplayIdentity]) {
        self.displays = displays
    }

    /// Display `index`, clamped so a scenario still builds on fewer monitors (the runner reports the shortfall).
    func display(_ index: Int) -> DisplayIdentity {
        displays[min(max(index, 0), displays.count - 1)]
    }

    /// A frame in reference coordinates (2560 x 1415 visible area), scaled onto display `d`'s visible frame.
    func frame(_ d: Int, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        let vis = display(d).visibleFrame
        let sx = vis.width / DebugFixtures.referenceWidth
        let sy = vis.height / DebugFixtures.referenceHeight
        return CGRect(x: (vis.minX + x * sx).rounded(), y: (vis.minY + y * sy).rounded(),
                      width: (w * sx).rounded(), height: (h * sy).rounded())
    }

    /// Adds `count` Desktops (1-based numbers) on display `d`, after any existing Spaces of that display.
    mutating func desktops(_ count: Int, on d: Int) {
        let disp = display(d)
        let start = spaces.filter { $0.displayUUID == disp.uuid }.count
        for n in 0..<count {
            spaces.append(SpaceSnapshot(displayUUID: disp.uuid, position: start + n, kind: .desktop,
                                        desktopNumber: n + 1))
        }
    }

    /// Adds a normal window. `desktop` nil means "Assign to all Desktops".
    @discardableResult
    mutating func add(_ bundle: String, _ name: String, _ frame: CGRect, on d: Int, desktop: Int?, z: Int,
                       title: String? = nil, match: TitleMatch = .any, index: Int = 0,
                       minimized: Bool = false, documentPath: String? = nil) -> UUID {
        let disp = display(d)
        let rel = relative(frame, to: disp)
        let window = WindowSnapshot(app: AppRef(bundleID: bundle, name: name), title: title, titleMatch: match,
                                    documentPath: documentPath, indexInApp: index, displayUUID: disp.uuid,
                                    frame: frame, relativeFrame: rel,
                                    placement: desktop.map { .desktop(number: $0) } ?? .allDesktops,
                                    isMinimized: minimized, zIndex: z)
        windows.append(window)
        return window.id
    }

    /// Adds a window that owns a full-screen Space at `position` (after the Desktops of display `d`).
    mutating func addFullScreen(_ bundle: String, _ name: String, _ frame: CGRect, on d: Int, position: Int, z: Int) {
        let disp = display(d)
        let id = add(bundle, name, frame, on: d, desktop: nil, z: z)
        // `add` stored it as allDesktops; rewrite it as the full-screen window of its own Space.
        if let i = windows.lastIndex(where: { $0.id == id }) {
            windows[i].placement = .fullScreen(position: position)
            windows[i].isFullScreen = true
        }
        spaces.append(SpaceSnapshot(displayUUID: disp.uuid, position: position, kind: .fullScreen,
                                    desktopNumber: nil, fullScreenWindowIDs: [id]))
    }

    private func relative(_ frame: CGRect, to display: DisplayIdentity) -> CGRect {
        let vis = display.visibleFrame
        return CGRect(x: (frame.minX - vis.minX) / vis.width, y: (frame.minY - vis.minY) / vis.height,
                      width: frame.width / vis.width, height: frame.height / vis.height)
    }
}
