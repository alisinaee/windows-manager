import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite struct StageManagerTests {
    typealias F = RestoreFixtures

    static let far = CGRect(x: -5000, y: 100, width: 300, height: 200)

    @Test func offscreenDetection() {
        let displays = [F.displayA()]
        #expect(StageManager.isParkedOffscreen(Self.far, displays: displays))
        #expect(!StageManager.isParkedOffscreen(CGRect(x: 100, y: 100, width: 800, height: 600), displays: displays))
        // Sticking out a bit is fine.
        #expect(!StageManager.isParkedOffscreen(CGRect(x: -300, y: 100, width: 800, height: 600), displays: displays))
    }

    @Test func annotateMarksParkedWindowsOnlyWhenOn() {
        let parked = F.live(1, F.chrome, frame: Self.far)
        let shown = F.live(2, F.chrome)
        let full = F.live(3, F.notes, frame: Self.far, fullScreen: true)
        let scan = F.scan([parked, shown, full])
        let on = StageManager.annotate(scan, provider: .fixed(true))
        #expect(on.stageManagerOn == true)
        #expect(on.windows.map(\.isInStageStrip) == [true, false, false])
        let off = StageManager.annotate(scan, provider: .fixed(false))
        #expect(off.stageManagerOn == false)
        #expect(off.windows.allSatisfy { !$0.isInStageStrip })
        #expect(StageManager.annotate(scan, provider: .fixed(nil)).stageManagerOn == nil)
    }

    @Test func captureRecordsStageManager() {
        let scan = WorkspaceScan(displays: [F.displayA()], windows: [F.live(1, F.chrome)], stageManagerOn: true)
        #expect(ProfileCapture.makeProfile(name: "p", from: scan).0.stageManagerOn == true)
        let plain = WorkspaceScan(displays: [F.displayA()], windows: [F.live(1, F.chrome)])
        #expect(ProfileCapture.makeProfile(name: "p", from: plain).0.stageManagerOn == nil)
    }

    @Test func profileFieldIsAdditive() throws {
        var profile = F.profile([F.snap(1, F.chrome)])
        profile.stageManagerOn = true
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(Profile.self, from: data).stageManagerOn == true)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "stageManagerOn")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Profile.self, from: old).stageManagerOn == nil)
    }

    // MARK: Detection with CGWindowList flags (P6.57)

    static let terminal = AppRef(bundleID: "com.apple.Terminal", name: "Terminal")
    static let v2box = AppRef(bundleID: "com.v2box.app", name: "V2Box")

    /// Stage Manager keeps the original frames, so every window here is fully on the screen.
    static func win(_ id: UInt32, _ app: AppRef, onScreen: Bool?, hidden: Bool = false, minimized: Bool = false,
                    onCurrentSpace: Bool = true) -> LiveWindow {
        LiveWindow(windowID: id, app: app, frame: CGRect(x: 100, y: 100, width: 800, height: 600),
                   isMinimized: minimized, isOnCurrentSpace: onCurrentSpace, isOnScreen: onScreen, isAppHidden: hidden)
    }

    @Test func userCaseTerminalInStripOthersActive() {
        let scan = F.scan([Self.win(1, Self.terminal, onScreen: false), Self.win(2, Self.v2box, onScreen: true),
                           Self.win(3, F.finder, onScreen: true), Self.win(4, F.finder, onScreen: true)])
        let result = StageManager.annotate(scan, provider: .fixed(true))
        #expect(result.windows.map(\.isInStageStrip) == [true, false, false, false])
        #expect(result.windows[0].stage == SavedStage(group: 1, isActive: false, isHeuristic: true))
        for window in result.windows.dropFirst() { #expect(window.stage == SavedStage(group: 0, isActive: true, isHeuristic: false)) }
    }

    @Test func stripWindowsAreGroupedByApp() {
        let scan = F.scan([Self.win(1, Self.terminal, onScreen: false), Self.win(2, F.finder, onScreen: false),
                           Self.win(3, Self.terminal, onScreen: false)])
        let groups = StageManager.annotate(scan, provider: .fixed(true)).windows.map { $0.stage?.group }
        #expect(groups == [1, 2, 1])
    }

    @Test func notStripWhenMinimizedHiddenOrOtherSpace() {
        let scan = F.scan([Self.win(1, Self.terminal, onScreen: false, minimized: true),
                           Self.win(2, Self.v2box, onScreen: false, hidden: true),
                           Self.win(3, F.finder, onScreen: false, onCurrentSpace: false)])
        let result = StageManager.annotate(scan, provider: .fixed(true))
        #expect(result.windows.allSatisfy { !$0.isInStageStrip && $0.stage == nil })
    }

    @Test func nothingIsFlaggedWhenStageManagerIsOffOrUnknown() {
        let scan = F.scan([Self.win(1, Self.terminal, onScreen: false)])
        for value in [false, nil] as [Bool?] {
            let result = StageManager.annotate(scan, provider: .fixed(value))
            #expect(!result.windows[0].isInStageStrip && result.windows[0].stage == nil)
        }
    }

    @Test func offscreenFrameIsTheHeuristicFallback() {
        let parked = LiveWindow(windowID: 1, app: F.chrome, frame: Self.far)
        let result = StageManager.annotate(F.scan([parked]), provider: .fixed(true))
        #expect(result.windows[0].isInStageStrip)
        #expect(StageManager.classify(parked, displays: [F.displayA()]) == .init(state: .strip, isHeuristic: true))
    }

    @Test func captureSavesStage() {
        let scan = StageManager.annotate(F.scan([Self.win(1, Self.terminal, onScreen: false), Self.win(2, F.finder, onScreen: true)]),
                                         provider: .fixed(true))
        let profile = ProfileCapture.makeProfile(name: "p", from: scan).0
        #expect(profile.windows.map(\.stage) == [SavedStage(group: 1, isActive: false, isHeuristic: true),
                                                SavedStage(group: 0, isActive: true, isHeuristic: false)])
    }

    @Test func savedStageIsAdditiveInJSON() throws {
        var snapshot = F.snap(1, F.chrome)
        snapshot.stage = SavedStage(group: 2, isActive: false, isHeuristic: true)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(WindowSnapshot.self, from: data).stage == snapshot.stage)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "stage")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(WindowSnapshot.self, from: old).stage == nil)
    }

    @Test func windowSavedInStripIsNotMovedOnRestore() {
        var strip = F.snap(1, F.chrome, title: "A", index: 0)
        strip.stage = SavedStage(group: 1, isActive: false, isHeuristic: true)
        let profile = F.profile([strip, F.snap(2, F.chrome, title: "B", index: 1)])
        var scan = F.scan([F.live(10, F.chrome, title: "A", index: 0), F.live(11, F.chrome, title: "B", index: 1)])
        scan.stageManagerOn = true
        let plan = F.plan(profile, scan)
        #expect(plan.steps.allSatisfy { $0.target?.windowID != 10 })
        #expect(plan.warnings.contains { $0.contains("strip or another stage") && $0.contains("captured") })
    }

    @Test func parkedWindowIsLeftAloneWithWarning() {
        let moved = CGRect(x: 10, y: 10, width: 500, height: 400)
        let profile = F.profile([F.snap(1, F.chrome, title: "A", index: 0), F.snap(2, F.chrome, title: "B", index: 1)])
        var scan = F.scan([F.live(10, F.chrome, title: "A", frame: moved, index: 0),
                           F.live(11, F.chrome, title: "B", frame: Self.far, index: 1, ).withStrip()])
        scan.stageManagerOn = true
        let plan = F.plan(profile, scan)
        #expect(plan.steps.allSatisfy { $0.target?.windowID != 11 })
        #expect(plan.steps.contains { $0.target?.windowID == 10 })
        #expect(plan.unmatched.isEmpty)
        #expect(plan.warnings.contains { $0.contains("Stage Manager is on") && $0.contains("11") })
    }

    @Test func parkedWindowIsMovedWhenStageManagerIsOff() {
        let profile = F.profile([F.snap(1, F.chrome, title: "A")])
        var scan = F.scan([F.live(10, F.chrome, title: "A", frame: Self.far).withStrip()])
        scan.stageManagerOn = false
        let plan = F.plan(profile, scan)
        #expect(plan.steps.contains { $0.target?.windowID == 10 })
        #expect(!plan.warnings.contains { $0.contains("Stage Manager is on") })
    }

    @Test func missingWindowWithParkedSiblingIsAWarningNotMissing() {
        let profile = F.profile([F.snap(1, F.chrome, title: "A", index: 0), F.snap(2, F.chrome, title: "B", index: 1),
                                   F.snap(3, F.chrome, title: "C", index: 2)])
        var scan = F.scan([F.live(10, F.chrome, title: "A", frame: F.defaultFrame, index: 0),
                           F.live(12, F.chrome, title: "Z", frame: Self.far, index: 1).withStrip()])
        scan.stageManagerOn = true
        let plan = F.plan(profile, scan)
        #expect(plan.unmatched.isEmpty)
        #expect(plan.warnings.contains { $0.contains("may be in the strip") })
    }

    @Test func differingStateIsOnlyInformational() {
        var profile = F.profile([F.snap(1, F.chrome)])
        profile.stageManagerOn = false
        var scan = F.scan([F.live(10, F.chrome)])
        scan.stageManagerOn = true
        let plan = F.plan(profile, scan)
        #expect(plan.warnings.contains { $0.contains("was off when this profile was captured") })
        #expect(!plan.warnings.joined().lowercased().contains("turn"))
    }

    // MARK: Strip thumbnails (P6.61)

    /// The monitor layout of the reporting Mac: PHL at -408,-1080 (1920x1080) and the built-in at 0,0.
    static let phl = DisplayIdentity(uuid: "PHL", name: "PHL", frame: CGRect(x: -408, y: -1080, width: 1920, height: 1080),
                                     visibleFrame: CGRect(x: -408, y: -1080, width: 1920, height: 1055), isMain: false, isBuiltIn: false)
    static let builtIn = DisplayIdentity(uuid: "BUILTIN", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 957), isMain: true, isBuiltIn: true)
    static let thumbnailBounds = CGRect(x: -393, y: -574, width: 118, height: 97)
    static let bigTerminal = CGRect(x: 100, y: 100, width: 500, height: 500)

    /// The Terminal thumbnail as the scanner builds it: on screen, flagged, window-server bounds.
    static func thumbnail(_ id: UInt32, _ app: AppRef, at bounds: CGRect = thumbnailBounds,
                          title: String? = "ali — ali@al…") -> LiveWindow {
        var window = LiveWindow(windowID: id, app: app, title: title, frame: bounds, isOnCurrentSpace: true,
                                isOnScreen: true, isStripThumbnail: true)
        window.serverBounds = bounds
        return window
    }

    static func real(_ id: UInt32, _ app: AppRef, onScreen: Bool?, frame: CGRect = bigTerminal) -> LiveWindow {
        LiveWindow(windowID: id, app: app, frame: frame, isOnCurrentSpace: true, isOnScreen: onScreen)
    }

    @Test func thumbnailShapeMatchesTheMeasuredFacts() {
        let displays = [Self.phl, Self.builtIn]
        #expect(StageManager.isStripThumbnailShape(Self.thumbnailBounds, isOnScreen: true, displays: displays))
        // The real Terminal window is not small, and it is not on screen.
        #expect(!StageManager.isStripThumbnailShape(Self.bigTerminal, isOnScreen: true, displays: displays))
        #expect(!StageManager.isStripThumbnailShape(Self.thumbnailBounds, isOnScreen: nil, displays: displays))
        #expect(!StageManager.isStripThumbnailShape(Self.thumbnailBounds, isOnScreen: false, displays: displays))
        // Small but in the middle of a monitor: an ordinary small window.
        #expect(!StageManager.isStripThumbnailShape(CGRect(x: 600, y: 300, width: 150, height: 120), isOnScreen: true,
                                                     displays: displays))
    }

    @Test func terminalThumbnailIsTheStripAndCertain() {
        let scan = F.scan([Self.thumbnail(9, Self.terminal)], displays: [Self.phl, Self.builtIn])
        let result = StageManager.annotate(scan, provider: .fixed(true))
        #expect(result.windows.map(\.windowID) == [9])
        #expect(result.windows[0].isInStageStrip)
        #expect(result.windows[0].stage == SavedStage(group: 1, isActive: false, isHeuristic: false))
    }

    @Test func thumbnailsOfOneStageShareAGroupAndAFarOneGetsTheNext() {
        // Stage 1 is two overlapping thumbnails. The far one lies lower on the same strip, so it is stage 2.
        let far = Self.thumbnail(3, Self.v2box, at: CGRect(x: -393, y: -400, width: 118, height: 97))
        let top = Self.thumbnail(1, Self.terminal)
        let overlapping = Self.thumbnail(2, Self.terminal, at: CGRect(x: -393, y: -560, width: 118, height: 97))
        let scan = F.scan([far, top, overlapping], displays: [Self.phl, Self.builtIn])
        let result = StageManager.annotate(scan, provider: .fixed(true))
        #expect(result.windows.map(\.stage?.group) == [2, 1, 1])
        #expect(result.windows.allSatisfy { $0.stage?.isHeuristic == false && $0.isInStageStrip })
    }

    @Test func thumbnailsFortyPointsApartAreTwoStages() {
        // 40 pt between the rectangles is more than the 30 pt limit, so they are two stages.
        let upper = Self.thumbnail(1, Self.terminal, at: CGRect(x: -393, y: -574, width: 118, height: 97))
        let lower = Self.thumbnail(2, Self.v2box, at: CGRect(x: -393, y: -437, width: 118, height: 97))
        let result = StageManager.annotate(F.scan([lower, upper], displays: [Self.phl, Self.builtIn]), provider: .fixed(true))
        #expect(result.windows.map(\.stage?.group) == [2, 1])
    }

    @Test func thumbnailsOnDifferentDisplaysNeverShareAGroup() {
        // The two rectangles overlap in y, but one is on PHL and the other on the built-in display.
        let phlThumb = Self.thumbnail(1, Self.terminal, at: CGRect(x: 1300, y: -60, width: 118, height: 97))
        let builtInThumb = Self.thumbnail(2, Self.v2box, at: CGRect(x: 1300, y: 20, width: 118, height: 97))
        let result = StageManager.annotate(F.scan([phlThumb, builtInThumb], displays: [Self.phl, Self.builtIn]),
                                           provider: .fixed(true))
        #expect(result.windows.map(\.stage?.group) == [1, 2])
    }

    @Test func thumbnailOfOneAppDoesNotMarkOtherApps() {
        let scan = F.scan([Self.thumbnail(9, Self.terminal), Self.real(3, Self.v2box, onScreen: nil)])
        let result = StageManager.annotate(scan, provider: .fixed(true))
        #expect(result.windows.first { $0.windowID == 3 }?.stage == nil)
        #expect(result.windows.first { $0.windowID == 9 }?.isInStageStrip == true)
    }

    @Test func visibleWindowsOfOtherAppsAreActive() {
        let scan = F.scan([Self.thumbnail(9, Self.terminal),
                           Self.real(2, Self.v2box, onScreen: true, frame: CGRect(x: 40, y: 40, width: 600, height: 500)),
                           Self.real(3, F.finder, onScreen: true, frame: CGRect(x: 700, y: 40, width: 600, height: 500)),
                           Self.real(4, F.finder, onScreen: true, frame: CGRect(x: 700, y: 560, width: 600, height: 400))])
        let result = StageManager.annotate(scan, provider: .fixed(true))
        #expect(result.windows.map(\.windowID) == [9, 2, 3, 4])
        #expect(result.windows[1...].allSatisfy { $0.stage == SavedStage(group: 0, isActive: true, isHeuristic: false) })
        #expect(result.windows[0].stage == SavedStage(group: 1, isActive: false, isHeuristic: false))
    }

    @Test func onScreenWindowOnAnotherSpaceIsStillActive() {
        let window = LiveWindow(windowID: 1, app: F.finder, frame: F.defaultFrame, isOnCurrentSpace: false, isOnScreen: true)
        #expect(StageManager.classify(window, displays: [F.displayA()]) == .init(state: .active, isHeuristic: false))
        let result = StageManager.annotate(F.scan([window]), provider: .fixed(true))
        #expect(result.windows[0].stage == SavedStage(group: 0, isActive: true, isHeuristic: false))
    }

    @Test func offscreenWindowOnCurrentSpaceWithoutThumbnailIsAGuessedStrip() {
        let window = Self.real(1, Self.terminal, onScreen: false)
        #expect(StageManager.classify(window, displays: [Self.builtIn]) == .init(state: .strip, isHeuristic: true))
        let result = StageManager.annotate(F.scan([window]), provider: .fixed(true))
        #expect(result.windows[0].isInStageStrip)
        #expect(result.windows[0].stage == SavedStage(group: 1, isActive: false, isHeuristic: true))
    }

    @Test func appWithoutThumbnailAndNoOnScreenFlagIsUnknown() {
        let scan = F.scan([Self.real(1, Self.terminal, onScreen: nil), Self.real(2, F.finder, onScreen: nil)])
        let result = StageManager.annotate(scan, provider: .fixed(true))
        #expect(result.windows.allSatisfy { $0.stage == nil && !$0.isInStageStrip })
        #expect(StageManager.classify(Self.real(1, Self.terminal, onScreen: nil), displays: [Self.builtIn])
            == .init(state: .unknown, isHeuristic: false))
    }

    @Test func onScreenWindowIsNotParkedEvenWhenItsFrameIsOffEveryMonitor() {
        let onScreen = LiveWindow(windowID: 1, app: F.chrome, frame: Self.far, isOnScreen: true)
        #expect(StageManager.classify(onScreen, displays: [F.displayA()]) == .init(state: .active, isHeuristic: false))
    }

    @Test func thumbnailIsNeverActive() {
        let thumb = Self.thumbnail(9, Self.terminal)
        #expect(StageManager.classify(thumb, displays: [Self.builtIn]).state != .active)
    }

    @Test func scannerKeepsThumbnailOnlyWithStageManagerOn() {
        let display = Self.phl
        let catalog = [CatalogWindow(windowID: 9, pid: 500, appName: "Terminal", title: "ali — ali@al…",
                                     bounds: Self.thumbnailBounds, isOnScreen: true, spaceIDs: [])]
        let apps: (Int32) -> AppRef? = { _ in Self.terminal }
        let on = WorkspaceScanner.assemble(displays: [display], skyLight: [], catalog: catalog, activeSpaceID: 0,
                                           appRef: apps, ax: [:], stageManagerOn: true)
        #expect(on.windows.map(\.isStripThumbnail) == [true])
        #expect(on.windows[0].frame == Self.thumbnailBounds)
        let off = WorkspaceScanner.assemble(displays: [display], skyLight: [], catalog: catalog, activeSpaceID: 0,
                                            appRef: apps, ax: [:], stageManagerOn: false)
        #expect(off.windows.isEmpty)
    }

    @Test func thumbnailFrameIsNotReplacedByAccessibilityFrame() {
        let display = Self.phl
        let catalog = [CatalogWindow(windowID: 9, pid: 500, appName: "Terminal", title: nil,
                                     bounds: Self.thumbnailBounds, isOnScreen: true, spaceIDs: [4])]
        // Accessibility hands the thumbnail's id the real window's frame; the thumbnail keeps its own bounds.
        let ax: [UInt32: AXWindowDetails] = [9: AXWindowDetails(title: nil, documentPath: nil, isMinimized: false,
                                                                frame: Self.bigTerminal)]
        let scan = WorkspaceScanner.assemble(displays: [display], skyLight: [], catalog: catalog, activeSpaceID: 4,
                                             appRef: { _ in Self.terminal }, ax: ax, stageManagerOn: true)
        #expect(scan.windows.first?.frame == Self.thumbnailBounds)
        #expect(scan.windows.first?.isStripThumbnail == true)
    }
}

private extension LiveWindow {
    func withStrip() -> LiveWindow { var copy = self; copy.isInStageStrip = true; return copy }
}
