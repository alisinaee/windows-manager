import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// Tests for the workspace scanner's pure parts and for capturing a scan into a profile. Fixtures are modelled
/// on a real setup: a main 4K display with [Chrome FS, Telegram FS, Desktop 1, Arc FS, Claude FS] and the
/// built-in display with [Code FS, Code FS, Desktop 1].
@Suite struct ProfileCaptureTests {
    // MARK: Fixtures

    static let mainUUID = "5B2E7C10-0000-4000-8000-0000000032A1"
    static let builtInUUID = "37D8832A-2D66-02CA-B9F7-8F30A301B230"

    /// 2560x1440 with a 40 pt menu bar.
    static let main = DisplayIdentity(
        uuid: mainUUID, name: "U32R59x", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 40, width: 2560, height: 1360), isMain: true, isBuiltIn: false)
    /// Left of the main display, lower than it.
    static let builtIn = DisplayIdentity(
        uuid: builtInUUID, name: "Built-in Retina Display", frame: CGRect(x: -1512, y: 440, width: 1512, height: 982),
        visibleFrame: CGRect(x: -1512, y: 480, width: 1512, height: 940), isMain: false, isBuiltIn: true)

    /// Deterministic snapshot ids: sid(1) ... sid(99).
    static func sid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static func space(_ id: UInt64, _ index: Int, kind: SpaceKind = .desktop, current: Bool = false, owner: Int32? = nil,
                      windows: [UInt32] = [], apps: [String] = []) -> SpaceInfo {
        SpaceInfo(id: id, uuid: "S-\(id)", kind: kind, index: index, isCurrent: current, fullScreenOwnerPID: owner,
                  fullScreenWindowIDs: windows, ownerAppNames: apps)
    }

    static func cw(_ id: UInt32, _ pid: Int32, _ app: String, _ title: String? = nil, _ bounds: CGRect,
                   spaces: [UInt64], alpha: Double = 1) -> CatalogWindow {
        CatalogWindow(windowID: id, pid: pid, appName: app, title: title, bounds: bounds, alpha: alpha,
                      isOnScreen: !spaces.isEmpty, spaceIDs: spaces)
    }

    static func app(_ name: String, _ bundleID: String?) -> AppRef {
        AppRef(bundleID: bundleID, name: name, path: bundleID == nil ? nil : "/Applications/\(name).app")
    }

    static func live(_ id: UInt32, _ app: AppRef, title: String? = "w", frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600),
                     display: String? = mainUUID, spaces: [UInt64], fullScreen: Bool = false, minimized: Bool = false,
                     index: Int = 0) -> LiveWindow {
        LiveWindow(windowID: id, pid: Int32(id), app: app, title: title, frame: frame, displayUUID: display,
                   spaceIDs: spaces, isFullScreen: fullScreen, isMinimized: minimized, indexInApp: index)
    }

    /// The raw readings of the real-setup fixture.
    struct Setup {
        var displays: [DisplayIdentity]
        var skyLight: [DisplaySpaces]
        var catalog: [CatalogWindow]
        var apps: [Int32: AppRef]
        var ax: [UInt32: AXWindowDetails]
    }

    static let fullMain = CGRect(x: 0, y: 40, width: 2560, height: 1360)
    static let fullBuiltIn = CGRect(x: -1512, y: 480, width: 1512, height: 940)

    static func realSetup() -> Setup {
        let skyLight = [
            DisplaySpaces(displayIdentifier: "Main", displayName: "U32R59x", currentSpaceID: 12, spaces: [
                space(10, 0, kind: .fullscreen, owner: 2001, windows: [84], apps: ["Google Chrome"]),
                space(11, 1, kind: .fullscreen, owner: 2002, windows: [150], apps: ["Telegram"]),
                space(12, 2, current: true),
                space(13, 3, kind: .fullscreen, owner: 2003, windows: [160], apps: ["Arc"]),
                space(14, 4, kind: .fullscreen, owner: 2004, windows: [170], apps: ["Claude"]),
            ]),
            // SkyLight spells the UUID in lower case here on purpose.
            DisplaySpaces(displayIdentifier: builtInUUID.lowercased(), displayName: "Built-in Retina Display",
                          currentSpaceID: 22, spaces: [
                space(20, 0, kind: .fullscreen, owner: 2005, windows: [200], apps: ["Code"]),
                space(21, 1, kind: .fullscreen, owner: 2005, windows: [201], apps: ["Code"]),
                space(22, 2, current: true),
            ]),
        ]
        // Front to back, with everything a real window list holds besides the windows people care about.
        let catalog = [
            cw(900, 649, "WindowManager", "Gesture Blocking Overlay", CGRect(x: 852, y: 197, width: 1031, height: 891), spaces: [12]),
            cw(901, 650, "Dock", nil, CGRect(x: 0, y: 0, width: 2560, height: 1440), spaces: [12]),
            cw(100, 1000, "Finder", "Downloads", CGRect(x: 640, y: 380, width: 1280, height: 680), spaces: [12]),
            cw(101, 1001, "Terminal", "~ - zsh", CGRect(x: 320, y: 240, width: 800, height: 500), spaces: [12]),
            cw(902, 3000, "Windows Manager", "Profiles", CGRect(x: 200, y: 200, width: 600, height: 400), spaces: [12]),
            cw(102, 1001, "Terminal", nil, CGRect(x: 360, y: 280, width: 800, height: 500), spaces: [12]),
            cw(84, 2001, "Google Chrome", "Inbox", CGRect(x: 0, y: 0, width: 2560, height: 1440), spaces: [10]),
            cw(89, 2001, "Google Chrome", nil, CGRect(x: 0, y: 0, width: 2560, height: 124), spaces: [10]),
            cw(150, 2002, "Telegram", "Telegram", fullMain, spaces: [11]),
            cw(160, 2003, "Arc", "ali", fullMain, spaces: [13]),
            cw(170, 2004, "Claude", "Claude", fullMain, spaces: [14]),
            cw(200, 2005, "Code", "project-a", fullBuiltIn, spaces: [20]),
            cw(201, 2005, "Code", "project-b", fullBuiltIn, spaces: [21]),
            cw(300, 2006, "Free Download Manager", "Free Download Manager",
               CGRect(x: -1134, y: 715, width: 756, height: 470), spaces: [22]),
            cw(903, 1001, "Terminal", nil, CGRect(x: 0, y: 482, width: 500, height: 500), spaces: []),
            cw(904, 2001, "Google Chrome", nil, CGRect(x: 100, y: 100, width: 1218, height: 89), spaces: [12]),
        ]
        let apps: [Int32: AppRef] = [
            649: app("WindowManager", "com.apple.WindowManager"), 650: app("Dock", "com.apple.dock"),
            1000: app("Finder", "com.apple.finder"), 1001: app("Terminal", "com.apple.Terminal"),
            2001: app("Google Chrome", "com.google.Chrome"), 2002: app("Telegram", "ru.keepcoder.Telegram"),
            2003: app("Arc", "company.thebrowser.Browser"), 2004: app("Claude", "com.anthropic.claudefordesktop"),
            2005: app("Code", "com.microsoft.VSCode"), 2006: app("Free Download Manager", "org.freedownloadmanager.fdm"),
            3000: app("Windows Manager", WorkspaceScanner.ownBundleID),
        ]
        // Accessibility only reaches the Desktops that are visible.
        let ax: [UInt32: AXWindowDetails] = [
            300: AXWindowDetails(title: "Free Download Manager", documentPath: "/Users/ali/Downloads/a.torrent", isMinimized: false),
            101: AXWindowDetails(title: "~ - zsh", documentPath: nil, isMinimized: false),
        ]
        return Setup(displays: [main, builtIn], skyLight: skyLight, catalog: catalog, apps: apps, ax: ax)
    }

    static func scan(_ setup: Setup, options: ScanOptions = ScanOptions()) -> WorkspaceScan {
        WorkspaceScanner.assemble(displays: setup.displays, skyLight: setup.skyLight, catalog: setup.catalog,
                                  activeSpaceID: 12, appRef: { setup.apps[$0] }, ax: setup.ax, options: options)
    }

    /// Scan and profile of the real-setup fixture, with deterministic snapshot ids sid(1)... in window order.
    static func realProfile() -> (scan: WorkspaceScan, profile: Profile, warnings: [String]) {
        let scan = Self.scan(realSetup())
        var n = 0
        let (profile, warnings) = ProfileCapture.makeProfile(name: "Home", from: scan, now: Date(timeIntervalSince1970: 0)) {
            n += 1
            return sid(n)
        }
        return (scan, profile, warnings)
    }

    /// The snapshot made from the live window with this id (all windows are captured, so the order is the same).
    static func snapshot(_ windowID: UInt32, _ scan: WorkspaceScan, _ profile: Profile) -> WindowSnapshot {
        let index = scan.windows.firstIndex { $0.windowID == windowID }!
        return profile.windows[index]
    }

    static func approx(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9 && abs(a.width - b.width) < 1e-9
            && abs(a.height - b.height) < 1e-9
    }

    // MARK: Scanner filter

    @Test func filterDropsStageManagerDockAndOurOwnWindows() {
        let ids = Self.scan(Self.realSetup()).windows.map(\.windowID)
        #expect(ids == [100, 101, 102, 84, 150, 160, 170, 200, 201, 300])
        // 900 Stage Manager overlay, 901 Dock, 902 our app, 903 no Space, 904 too thin, 89 full-screen overlay.
        for hidden: UInt32 in [900, 901, 902, 903, 904, 89] { #expect(!ids.contains(hidden)) }
    }

    @Test func filterRejectsSystemAppsByNameAndBundleID() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        func window(_ app: String) -> CatalogWindow { Self.cw(1, 1, app, "x", bounds, spaces: [1]) }

        for name in ["Dock", "Window Server", "Control Center", "SystemUIServer", "Notification Center", "WindowManager"] {
            #expect(!WorkspaceScanner.isUserWindow(window(name), bundleID: nil), "\(name) must be excluded")
        }
        for id in [WorkspaceScanner.ownBundleID, "com.apple.dock", "com.apple.controlcenter", "com.apple.systemuiserver",
                   "com.apple.notificationcenterui", "com.apple.WindowManager"] {
            #expect(!WorkspaceScanner.isUserWindow(window("Whatever"), bundleID: id), "\(id) must be excluded")
        }
        #expect(WorkspaceScanner.isUserWindow(window("Finder"), bundleID: "com.apple.finder"))
        #expect(WorkspaceScanner.isUserWindow(window("Finder"), bundleID: nil))

        // Caller-supplied bundle ids, any letter case.
        let options = ScanOptions(excludedBundleIDs: ["com.example.Ignore"])
        #expect(!WorkspaceScanner.isUserWindow(window("Ignore"), bundleID: "COM.EXAMPLE.ignore", options: options))
        #expect(WorkspaceScanner.isUserWindow(window("Ignore"), bundleID: "com.example.keep", options: options))
    }

    @Test func filterKeepsLookLikeUserWindowRules() {
        let big = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(!WorkspaceScanner.isUserWindow(Self.cw(1, 1, "Finder", nil, big, spaces: []), bundleID: nil))
        #expect(!WorkspaceScanner.isUserWindow(Self.cw(1, 1, "Finder", nil, CGRect(x: 0, y: 0, width: 800, height: 99), spaces: [1]), bundleID: nil))
        #expect(!WorkspaceScanner.isUserWindow(Self.cw(1, 1, "Finder", nil, big, spaces: [1], alpha: 0), bundleID: nil))
    }

    @Test func minimizedWindowsPassOnlyWhenAccessibilitySaysSo() throws {
        var setup = Self.realSetup()
        setup.catalog.append(Self.cw(950, 1000, "Finder", "Old", CGRect(x: 50, y: 60, width: 700, height: 500), spaces: []))
        #expect(!Self.scan(setup).windows.contains { $0.windowID == 950 })

        setup.ax[950] = AXWindowDetails(title: "Old", documentPath: nil, isMinimized: true)
        let scan = Self.scan(setup)
        let window = try #require(scan.window(withID: 950))
        #expect(window.isMinimized)
        #expect(window.spaceIDs.isEmpty)
        #expect(!window.isOnCurrentSpace)
        #expect(WorkspaceScanner.placement(for: window, in: scan) == .unknown)

        // The window is captured, with a warning about its placement.
        let (profile, warnings) = ProfileCapture.makeProfile(name: "x", from: scan)
        #expect(profile.windows.contains { $0.isMinimized && $0.placement == .unknown })
        #expect(warnings.contains { $0.contains("window 950") && $0.contains("minimized") })
    }

    @Test func fullScreenOverlayWindowsAreOptional() throws {
        let scan = Self.scan(Self.realSetup(), options: ScanOptions(includeFullScreenHelperWindows: true))
        let helper = try #require(scan.window(withID: 89))
        #expect(!helper.isFullScreen)
        #expect(scan.window(withID: 84)?.isFullScreen == true)
    }

    // MARK: Scanner assembly

    @Test func scanWindowsCarryAppDisplayAndSpaces() throws {
        let scan = Self.scan(Self.realSetup())
        let finder = try #require(scan.window(withID: 100))
        #expect(finder.app == Self.app("Finder", "com.apple.finder"))
        #expect(finder.title == "Downloads")
        #expect(finder.displayUUID == Self.mainUUID)
        #expect(finder.spaceIDs == [12])
        #expect(finder.frame == CGRect(x: 640, y: 380, width: 1280, height: 680))
        #expect(finder.isOnCurrentSpace)
        #expect(!finder.isFullScreen)

        let manager = try #require(scan.window(withID: 300))
        #expect(manager.displayUUID == Self.builtInUUID)
        #expect(manager.documentPath == "/Users/ali/Downloads/a.torrent")
        #expect(manager.isOnCurrentSpace)

        let chrome = try #require(scan.window(withID: 84))
        #expect(chrome.isFullScreen)
        #expect(!chrome.isOnCurrentSpace)
        #expect(chrome.displayUUID == Self.mainUUID)
    }

    @Test func scanKnowsOwnersOfFullScreenSpaces() {
        let scan = Self.scan(Self.realSetup())
        let fullScreen = Set(scan.windows.filter(\.isFullScreen).map(\.windowID))
        #expect(fullScreen == [84, 150, 160, 170, 200, 201])
    }

    @Test func scanMatchesSkyLightDisplaysToScreens() {
        let scan = Self.scan(Self.realSetup())
        // "Main" is the main display; the lower-case UUID is the built-in display.
        #expect(scan.spaces.map(\.displayUUID) == [Self.mainUUID, Self.builtInUUID])
        #expect(scan.spaces[0].skyLightIdentifier == "Main")
        #expect(scan.spaces[0].spaces.map(\.id) == [10, 11, 12, 13, 14])
        #expect(scan.spaces[1].spaces.map(\.id) == [20, 21, 22])
        #expect(scan.spaces(onDisplay: Self.builtInUUID.lowercased())?.currentSpaceID == 22)
        #expect(scan.notes.isEmpty)
    }

    @Test func scanWithUnknownSkyLightDisplayLeavesItOutAndSaysSo() {
        var setup = Self.realSetup()
        setup.skyLight.append(DisplaySpaces(displayIdentifier: "AAAAAAAA-0000-4000-8000-000000000000", displayName: nil,
                                            currentSpaceID: 99, spaces: [Self.space(99, 0, current: true)]))
        let scan = Self.scan(setup)
        #expect(scan.spaces.count == 2)
        #expect(scan.notes.count == 1)
        #expect(ProfileCapture.makeProfile(name: "x", from: scan).1.contains { $0.contains("AAAAAAAA") })
    }

    @Test func indexInAppFollowsFrontToBackOrderPerApp() {
        let scan = Self.scan(Self.realSetup())
        func index(_ id: UInt32) -> Int { scan.window(withID: id)!.indexInApp }
        #expect(index(101) == 0)
        #expect(index(102) == 1)
        #expect(index(200) == 0)
        #expect(index(201) == 1)
        for id: UInt32 in [100, 84, 150, 160, 170, 300] { #expect(index(id) == 0) }
    }

    @Test func titleFallsBackToAccessibility() {
        var setup = Self.realSetup()
        setup.catalog = [Self.cw(10, 1000, "Finder", nil, CGRect(x: 0, y: 40, width: 800, height: 600), spaces: [12])]
        setup.ax = [10: AXWindowDetails(title: "From AX", documentPath: nil, isMinimized: false)]
        #expect(Self.scan(setup).windows.first?.title == "From AX")

        setup.catalog[0].title = "From CG"
        #expect(Self.scan(setup).windows.first?.title == "From CG")

        setup.ax = [:]
        setup.catalog[0].title = nil
        #expect(Self.scan(setup).windows.first?.title == nil)
    }

    @Test func fullScreenOwnerFallsBackToTheBiggestWindowOnTheSpace() {
        // SkyLight names window 5, which is not in the list; window 11 is the big one on that Space.
        let space = Self.space(50, 0, kind: .fullscreen, owner: 7, windows: [5])
        let windows = [
            Self.cw(10, 7, "Notes", nil, CGRect(x: 0, y: 0, width: 300, height: 200), spaces: [50]),
            Self.cw(11, 7, "Notes", "Big", CGRect(x: 0, y: 0, width: 1500, height: 900), spaces: [50]),
            Self.cw(12, 8, "Other", nil, CGRect(x: 0, y: 0, width: 3000, height: 2000), spaces: [50]),
        ]
        #expect(WorkspaceScanner.fullScreenOwners(spaces: [space], windows: windows) == [50: [11]])
        // Nothing on the Space: no owner.
        #expect(WorkspaceScanner.fullScreenOwners(spaces: [Self.space(51, 1, kind: .fullscreen, windows: [6])], windows: windows).isEmpty)
        // Desktops never have owners.
        #expect(WorkspaceScanner.fullScreenOwners(spaces: [Self.space(52, 2)], windows: windows).isEmpty)
    }

    // MARK: Placement

    @Test func placementsOfTheRealSetup() {
        let scan = Self.scan(Self.realSetup())
        func placement(_ id: UInt32) -> SpacePlacement { WorkspaceScanner.placement(for: scan.window(withID: id)!, in: scan) }

        // Main display: [0] Chrome FS, [1] Telegram FS, [2] Desktop 1, [3] Arc FS, [4] Claude FS.
        #expect(placement(84) == .fullScreen(position: 0))
        #expect(placement(150) == .fullScreen(position: 1))
        #expect(placement(100) == .desktop(number: 1))
        #expect(placement(101) == .desktop(number: 1))
        #expect(placement(102) == .desktop(number: 1))
        #expect(placement(160) == .fullScreen(position: 3))
        #expect(placement(170) == .fullScreen(position: 4))
        // Built-in: [0] Code FS, [1] Code FS, [2] Desktop 1.
        #expect(placement(200) == .fullScreen(position: 0))
        #expect(placement(201) == .fullScreen(position: 1))
        #expect(placement(300) == .desktop(number: 1))
    }

    @Test func desktopNumbersSkipFullScreenSpaces() {
        let display = ScannedSpaces(displayUUID: Self.mainUUID, spaces: [
            Self.space(1, 0), Self.space(2, 1, kind: .fullscreen, windows: [9]), Self.space(3, 2), Self.space(4, 3),
        ])
        let scan = WorkspaceScan(displays: [Self.main], spaces: [display])
        let chrome = Self.app("Chrome", "com.google.Chrome")
        func placement(_ spaces: [UInt64], fullScreen: Bool = false) -> SpacePlacement {
            WorkspaceScanner.placement(for: Self.live(1, chrome, spaces: spaces, fullScreen: fullScreen), in: scan)
        }
        #expect(placement([1]) == .desktop(number: 1))
        #expect(placement([3]) == .desktop(number: 2))
        #expect(placement([4]) == .desktop(number: 3))
        #expect(placement([2], fullScreen: true) == .fullScreen(position: 1))
        #expect(placement([3, 4]) == .desktop(number: 2))
    }

    @Test func windowOnEveryDesktopIsAllDesktops() {
        let display = ScannedSpaces(displayUUID: Self.mainUUID, spaces: [
            Self.space(1, 0), Self.space(2, 1, kind: .fullscreen, windows: [9]), Self.space(3, 2),
        ])
        let other = ScannedSpaces(displayUUID: Self.builtInUUID, spaces: [Self.space(7, 0)])
        let scan = WorkspaceScan(displays: [Self.main, Self.builtIn], spaces: [display, other])
        let widget = Self.app("Widget", "com.example.widget")

        // On both Desktops of its display (the full-screen Space does not count), also listing another display's Space.
        #expect(WorkspaceScanner.placement(for: Self.live(1, widget, spaces: [1, 3, 7]), in: scan) == .allDesktops)
        // A single Desktop on a display with one Desktop is just that Desktop.
        #expect(WorkspaceScanner.placement(for: Self.live(2, widget, display: Self.builtInUUID, spaces: [7]), in: scan)
            == .desktop(number: 1))
    }

    @Test func placementIsUnknownWithoutAMatchingSpace() {
        let scan = WorkspaceScan(displays: [Self.main], spaces: [ScannedSpaces(displayUUID: Self.mainUUID, spaces: [Self.space(1, 0)])])
        let app = Self.app("Finder", "com.apple.finder")
        #expect(WorkspaceScanner.placement(for: Self.live(1, app, spaces: []), in: scan) == .unknown)
        #expect(WorkspaceScanner.placement(for: Self.live(2, app, spaces: [42]), in: scan) == .unknown)
        // The window's display has no Space list at all.
        #expect(WorkspaceScanner.placement(for: Self.live(3, app, display: Self.builtInUUID, spaces: [1]), in: scan) == .unknown)
    }

    // MARK: Capture: spaces

    @Test func captureKeepsSpacesInMissionControlOrder() {
        let (_, profile, _) = Self.realProfile()
        #expect(profile.displays == [Self.main, Self.builtIn])
        #expect(profile.monitorSetKey == DisplayMap.monitorSetKey([Self.main, Self.builtIn]))
        #expect(profile.name == "Home")

        let main = profile.spaces(onDisplay: Self.mainUUID)
        #expect(main.map(\.position) == [0, 1, 2, 3, 4])
        #expect(main.map(\.kind) == [.fullScreen, .fullScreen, .desktop, .fullScreen, .fullScreen])
        #expect(main.map(\.desktopNumber) == [nil, nil, 1, nil, nil])

        let builtIn = profile.spaces(onDisplay: Self.builtInUUID)
        #expect(builtIn.map(\.position) == [0, 1, 2])
        #expect(builtIn.map(\.kind) == [.fullScreen, .fullScreen, .desktop])
        #expect(builtIn.map(\.desktopNumber) == [nil, nil, 1])
        #expect(profile.spaces.count == 8)
    }

    @Test func captureMapsFullScreenSpacesToTheirOwnerSnapshots() {
        let (scan, profile, _) = Self.realProfile()
        func owner(_ windowID: UInt32) -> [UUID] { [Self.snapshot(windowID, scan, profile).id] }

        let main = profile.spaces(onDisplay: Self.mainUUID)
        #expect(main[0].fullScreenWindowIDs == owner(84))
        #expect(main[1].fullScreenWindowIDs == owner(150))
        #expect(main[2].fullScreenWindowIDs.isEmpty)
        #expect(main[3].fullScreenWindowIDs == owner(160))
        #expect(main[4].fullScreenWindowIDs == owner(170))

        let builtIn = profile.spaces(onDisplay: Self.builtInUUID)
        #expect(builtIn[0].fullScreenWindowIDs == owner(200))
        #expect(builtIn[1].fullScreenWindowIDs == owner(201))
        #expect(builtIn[2].fullScreenWindowIDs.isEmpty)

        // The two Code windows own different Spaces.
        #expect(owner(200) != owner(201))
        // And the profile is consistent: every owner id is a window of the profile.
        #expect(profile.validate().isEmpty)
    }

    @Test func splitViewSpaceHasBothOwners() {
        let notes = Self.app("Notes", "com.apple.Notes")
        let safari = Self.app("Safari", "com.apple.Safari")
        let display = ScannedSpaces(displayUUID: Self.mainUUID, spaces: [
            Self.space(1, 0), Self.space(2, 1, kind: .fullscreen, windows: [11, 12], apps: ["Safari + Notes"]),
        ])
        let scan = WorkspaceScan(displays: [Self.main], spaces: [display], windows: [
            Self.live(11, safari, spaces: [2], fullScreen: true), Self.live(12, notes, spaces: [2], fullScreen: true),
        ])
        let (profile, warnings) = ProfileCapture.makeProfile(name: "Split", from: scan)
        #expect(warnings.isEmpty)
        let space = profile.spaces(onDisplay: Self.mainUUID)[1]
        #expect(space.isSplitView)
        #expect(space.fullScreenWindowIDs == profile.windows.map(\.id))
        #expect(profile.windows.allSatisfy { $0.placement == .fullScreen(position: 1) })
    }

    // MARK: Capture: windows

    @Test func captureComputesRelativeFramesFromTheVisibleFrame() {
        let (scan, profile, _) = Self.realProfile()
        // Finder: x 640/2560, y (380-40)/1360, 1280/2560, 680/1360.
        let finder = Self.snapshot(100, scan, profile)
        #expect(Self.approx(finder.relativeFrame, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        #expect(finder.frame == CGRect(x: 640, y: 380, width: 1280, height: 680))
        #expect(finder.displayUUID == Self.mainUUID)

        // Free Download Manager on the built-in display: x 378/1512, y 235/940.
        let manager = Self.snapshot(300, scan, profile)
        #expect(Self.approx(manager.relativeFrame, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        #expect(manager.displayUUID == Self.builtInUUID)

        // Windows that own a full-screen Space fill the screen.
        for id: UInt32 in [84, 150, 160, 170, 200, 201] {
            #expect(Self.snapshot(id, scan, profile).relativeFrame == CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    @Test func relativeFrameIsNotClamped() {
        let frame = CGRect(x: -100, y: 40, width: 2760, height: 1360)
        let relative = ProfileCapture.relativeFrame(of: frame, in: Self.main)
        #expect(Self.approx(relative, CGRect(x: -100.0 / 2560, y: 0, width: 2760.0 / 2560, height: 1)))

        // A display with no visible frame uses its whole frame; one with no size at all gives the unit rect.
        var bare = Self.main
        bare.visibleFrame = .zero
        #expect(Self.approx(ProfileCapture.relativeFrame(of: CGRect(x: 1280, y: 720, width: 1280, height: 720), in: bare),
                            CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
        bare.frame = .zero
        #expect(ProfileCapture.relativeFrame(of: frame, in: bare) == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func captureKeepsStackingAndPerAppOrder() {
        let (scan, profile, _) = Self.realProfile()
        #expect(profile.windows.count == scan.windows.count)
        #expect(profile.windows.map(\.zIndex) == Array(0..<scan.windows.count))
        #expect(profile.windows.map(\.app.name) == scan.windows.map(\.app.name))

        let terminals = profile.windows(for: Self.app("Terminal", "com.apple.Terminal"))
        #expect(terminals.map(\.indexInApp) == [0, 1])
        #expect(terminals.map(\.zIndex) == [1, 2])
        let code = profile.windows(for: Self.app("Code", "com.microsoft.VSCode"))
        #expect(code.map(\.title) == ["project-a", "project-b"])
        #expect(code.map(\.indexInApp) == [0, 1])
    }

    @Test func captureDefaults() {
        let (scan, profile, _) = Self.realProfile()
        #expect(profile.windows.allSatisfy { $0.titleMatch == .any && $0.restore })
        #expect(profile.options == ProfileOptions())
        let chrome = Self.snapshot(84, scan, profile)
        #expect(chrome.isFullScreen)
        #expect(chrome.placement == .fullScreen(position: 0))
        #expect(chrome.app.bundleID == "com.google.Chrome")
        #expect(chrome.app.path == "/Applications/Google Chrome.app")
        #expect(Self.snapshot(300, scan, profile).documentPath == "/Users/ali/Downloads/a.torrent")
        #expect(Self.snapshot(300, scan, profile).placement == .desktop(number: 1))

        let custom = ProfileOptions(launchMissingApps: false, otherApps: .hide)
        #expect(ProfileCapture.makeProfile(name: "x", from: scan, options: custom).0.options == custom)
    }

    @Test func captureRoundTripsThroughJSON() throws {
        let (_, profile, _) = Self.realProfile()
        let data = try ProfileStore.encode(profile)
        let back = try ProfileStore.decode(data)
        #expect(back == profile)
    }

    // MARK: Warnings

    @Test func realSetupOnlyWarnsAboutTheUntitledWindow() {
        let (_, _, warnings) = Self.realProfile()
        // Terminal window 102 has no title anywhere.
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("Terminal"))
        #expect(warnings[0].contains("window 102"))
        #expect(warnings[0].contains("no title"))
    }

    @Test func warnsAboutAppsWithoutBundleIDOnce() {
        let odd = Self.app("Odd Tool", nil)
        let scan = WorkspaceScan(displays: [Self.main], spaces: [ScannedSpaces(displayUUID: Self.mainUUID, spaces: [Self.space(1, 0)])],
                                 windows: [Self.live(1, odd, title: "a", spaces: [1]), Self.live(2, odd, title: "b", spaces: [1], index: 1)])
        let warnings = ProfileCapture.makeProfile(name: "x", from: scan).1
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("Odd Tool"))
        #expect(warnings[0].contains("bundle id"))
    }

    @Test func warnsWhenFullScreenOwnerIsMissing() {
        let display = ScannedSpaces(displayUUID: Self.mainUUID, spaces: [
            Self.space(1, 0), Self.space(2, 1, kind: .fullscreen, windows: [77], apps: ["Ghost"]),
        ])
        let finder = Self.app("Finder", "com.apple.finder")
        let scan = WorkspaceScan(displays: [Self.main], spaces: [display], windows: [Self.live(1, finder, spaces: [1])])
        let (profile, warnings) = ProfileCapture.makeProfile(name: "x", from: scan)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("Space 2"))
        #expect(warnings[0].contains("Ghost"))
        #expect(warnings[0].contains("owner window"))
        // The Space is still saved, without owners.
        let space = profile.spaces(onDisplay: Self.mainUUID)[1]
        #expect(space.kind == .fullScreen)
        #expect(space.fullScreenWindowIDs.isEmpty)
    }

    @Test func warnsAboutHalfFoundSplitView() {
        let display = ScannedSpaces(displayUUID: Self.mainUUID, spaces: [Self.space(2, 0, kind: .fullscreen, windows: [11, 12])])
        let scan = WorkspaceScan(displays: [Self.main], spaces: [display],
                                 windows: [Self.live(11, Self.app("Safari", "com.apple.Safari"), spaces: [2], fullScreen: true)])
        let (profile, warnings) = ProfileCapture.makeProfile(name: "x", from: scan)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("2 windows but only 1"))
        #expect(profile.spaces[0].fullScreenWindowIDs.count == 1)
    }

    @Test func warnsAboutUnknownPlacement() {
        let finder = Self.app("Finder", "com.apple.finder")
        let scan = WorkspaceScan(displays: [Self.main], spaces: [ScannedSpaces(displayUUID: Self.mainUUID, spaces: [Self.space(1, 0)])],
                                 windows: [Self.live(5, finder, title: "Lost", spaces: [999])])
        let (profile, warnings) = ProfileCapture.makeProfile(name: "x", from: scan)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("unknown placement"))
        #expect(warnings[0].contains("window 5"))
        #expect(profile.windows[0].placement == .unknown)
    }

    @Test func scanNotesBecomeWarnings() {
        let scan = WorkspaceScan(displays: [Self.main], screenIsLocked: true,
                                 notes: ["The screen is locked, so document paths could not be read."])
        let warnings = ProfileCapture.makeProfile(name: "x", from: scan).1
        #expect(warnings == ["The screen is locked, so document paths could not be read."])
    }

    @Test func windowWithoutDisplayUUIDGoesToTheDisplayHoldingItsFrame() {
        let finder = Self.app("Finder", "com.apple.finder")
        let frame = CGRect(x: -1400, y: 600, width: 500, height: 400)
        let scan = WorkspaceScan(displays: [Self.main, Self.builtIn],
                                 spaces: [ScannedSpaces(displayUUID: Self.builtInUUID, spaces: [Self.space(7, 0)])],
                                 windows: [Self.live(1, finder, frame: frame, display: nil, spaces: [7])])
        let (profile, warnings) = ProfileCapture.makeProfile(name: "x", from: scan)
        #expect(warnings.isEmpty)
        #expect(profile.windows[0].displayUUID == Self.builtInUUID)
    }

    @Test func noDisplaysMeansNoWindowsAndAWarning() {
        let finder = Self.app("Finder", "com.apple.finder")
        let scan = WorkspaceScan(displays: [], windows: [Self.live(1, finder, display: nil, spaces: [1])])
        let (profile, warnings) = ProfileCapture.makeProfile(name: "x", from: scan)
        #expect(profile.windows.isEmpty)
        #expect(warnings.count >= 1)
        #expect(warnings.contains { $0.contains("left out") })
    }
}
