import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// PM2: Space index and map layout math. Covers the acceptance cases in docs/PLAN-profile-maps.md (section E, PM2).
@Suite struct ProfileMapLayoutTests {
    static let uuidA = "MAP00000-0000-4000-8000-00000000000A"
    static let uuidB = "MAP00000-0000-4000-8000-00000000000B"
    static let uuidC = "MAP00000-0000-4000-8000-00000000000C"
    static let viewport = CGSize(width: 1000, height: 800)

    static func display(_ uuid: String, _ frame: CGRect, visible: CGRect? = nil, main: Bool = false) -> DisplayIdentity {
        DisplayIdentity(uuid: uuid, name: "Display \(uuid.suffix(1))", frame: frame,
                        visibleFrame: visible ?? CGRect(x: frame.minX, y: frame.minY + 25,
                                                        width: frame.width, height: frame.height - 25),
                        isMain: main, isBuiltIn: false)
    }

    static func wid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", n))!
    }

    static func app(_ name: String) -> AppRef {
        AppRef(bundleID: "com.example.\(name.lowercased())", name: name)
    }

    static func window(_ n: Int, _ name: String = "App", display: String = uuidA, placement: SpacePlacement = .desktop(number: 1),
                       relative: CGRect = CGRect(x: 0, y: 0, width: 0.5, height: 0.5), z: Int = 0,
                       minimized: Bool = false, fullScreen: Bool = false, restore: Bool = true) -> WindowSnapshot {
        WindowSnapshot(id: wid(n), app: app(name), indexInApp: 0, displayUUID: display,
                       frame: CGRect(x: 100, y: 100, width: 400, height: 300), relativeFrame: relative,
                       placement: placement, isFullScreen: fullScreen, isMinimized: minimized, zIndex: z,
                       restore: restore)
    }

    static func profile(displays: [DisplayIdentity], spaces: [SpaceSnapshot] = [], windows: [WindowSnapshot]) -> Profile {
        Profile(name: "Test", monitorSetKey: "test", displays: displays, spaces: spaces, windows: windows)
    }

    static func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool {
        abs(a - b) <= tolerance
    }

    static func desktopSpace(_ display: String, _ position: Int, _ number: Int) -> SpaceSnapshot {
        SpaceSnapshot(displayUUID: display, position: position, kind: .desktop, desktopNumber: number)
    }

    // MARK: Space index

    @Test func indexGroupsWindowsByDesktopInMissionControlOrder() {
        let p = Self.profile(
            displays: [Self.display(Self.uuidA, CGRect(x: 0, y: 0, width: 1920, height: 1080), main: true)],
            spaces: [Self.desktopSpace(Self.uuidA, 0, 1), Self.desktopSpace(Self.uuidA, 1, 2)],
            windows: [Self.window(1, "Safari", placement: .desktop(number: 1)),
                      Self.window(2, "Notes", placement: .desktop(number: 2)),
                      Self.window(3, "Mail", placement: .desktop(number: 2), z: 1)])
        let index = ProfileSpaceIndex(profile: p)
        let spaces = index.spaces(onDisplay: Self.uuidA)

        #expect(spaces.map(\.desktopNumber) == [1, 2])
        #expect(spaces[0].windowIDs == [Self.wid(1)])
        // Back to front: the higher zIndex comes first, so Mail (z 1) before Notes (z 0).
        #expect(spaces[1].windowIDs == [Self.wid(3), Self.wid(2)])
        #expect(index.tray.isEmpty)
    }

    @Test func splitViewSpaceHoldsTwoOwnerWindows() {
        let p = Self.profile(
            displays: [Self.display(Self.uuidA, CGRect(x: 0, y: 0, width: 1920, height: 1080), main: true)],
            spaces: [Self.desktopSpace(Self.uuidA, 0, 1),
                     SpaceSnapshot(displayUUID: Self.uuidA, position: 1, kind: .fullScreen,
                                   fullScreenWindowIDs: [Self.wid(2), Self.wid(3)])],
            windows: [Self.window(1, "Safari", placement: .desktop(number: 1)),
                      Self.window(2, "Xcode", placement: .fullScreen(position: 1), fullScreen: true),
                      Self.window(3, "Notes", placement: .fullScreen(position: 1), z: 1, fullScreen: true)])
        let index = ProfileSpaceIndex(profile: p)
        let split = index.spaces(onDisplay: Self.uuidA)[1]

        #expect(split.kind == .fullScreen)
        #expect(split.isSplitView)
        #expect(split.windowIDs.count == 2)

        // The layout draws two equal halves of the content rect for the selected Split View Space.
        let layout = ProfileMapLayout.make(profile: p, index: index, selection: [Self.uuidA: split.id],
                                           viewport: Self.viewport)
        let content = layout.monitors[0].contentRect
        let halves = layout.windows.filter { $0.isSplitHalf }
        #expect(halves.count == 2)
        #expect(halves.allSatisfy { Self.near($0.rect.width, content.width / 2) })
        #expect(halves.allSatisfy { Self.near($0.rect.height, content.height) })
        let left = halves.min { $0.rect.minX < $1.rect.minX }!
        let right = halves.max { $0.rect.minX < $1.rect.minX }!
        #expect(Self.near(left.rect.minX, content.minX))
        #expect(Self.near(right.rect.minX, content.minX + content.width / 2))
    }

    @Test func allDesktopsWindowAppearsOnEveryDesktop() {
        let p = Self.profile(
            displays: [Self.display(Self.uuidA, CGRect(x: 0, y: 0, width: 1920, height: 1080), main: true)],
            spaces: [Self.desktopSpace(Self.uuidA, 0, 1), Self.desktopSpace(Self.uuidA, 1, 2),
                     Self.desktopSpace(Self.uuidA, 2, 3)],
            windows: [Self.window(9, "1Password", placement: .allDesktops),
                      Self.window(1, "Safari", placement: .desktop(number: 2))])
        let index = ProfileSpaceIndex(profile: p)
        let desktops = index.spaces(onDisplay: Self.uuidA)

        #expect(desktops.count == 3)
        #expect(desktops.allSatisfy { $0.windowIDs.contains(Self.wid(9)) })
        #expect(index.tray.contains { $0.windowID == Self.wid(9) && $0.reason == .onAllDesktops })

        let layout = ProfileMapLayout.make(profile: p, index: index, selection: [Self.uuidA: desktops[1].id],
                                           viewport: Self.viewport)
        let shown = layout.windows.first { $0.windowID == Self.wid(9) }
        #expect(shown?.isOnAllDesktops == true)
        #expect(shown?.spaceID == desktops[1].id)
    }

    @Test func minimizedWindowGoesToTray() {
        let p = Self.profile(
            displays: [Self.display(Self.uuidA, CGRect(x: 0, y: 0, width: 1920, height: 1080), main: true)],
            spaces: [Self.desktopSpace(Self.uuidA, 0, 1)],
            windows: [Self.window(1, "Notes", placement: .desktop(number: 1), minimized: true),
                      Self.window(2, "Safari", placement: .unknown)])
        let index = ProfileSpaceIndex(profile: p)

        #expect(index.spaces.allSatisfy { $0.windowIDs.isEmpty })
        #expect(index.tray.contains { $0.windowID == Self.wid(1) && $0.reason == .minimized })
        #expect(index.tray.contains { $0.windowID == Self.wid(2) && $0.reason == .unplaced })

        let layout = ProfileMapLayout.make(profile: p, index: index, viewport: Self.viewport)
        #expect(layout.windows.isEmpty)
    }

    @Test func defaultSpaceSelectionRule() {
        let display = Self.display(Self.uuidA, CGRect(x: 0, y: 0, width: 1920, height: 1080), main: true)
        let spaces = [Self.desktopSpace(Self.uuidA, 0, 1), Self.desktopSpace(Self.uuidA, 1, 2),
                      SpaceSnapshot(displayUUID: Self.uuidA, position: 2, kind: .fullScreen,
                                    fullScreenWindowIDs: [Self.wid(4)])]

        // Desktop 1 has windows: it is the default.
        let withDesktop1 = ProfileSpaceIndex(profile: Self.profile(
            displays: [display], spaces: spaces,
            windows: [Self.window(1, placement: .desktop(number: 1)), Self.window(2, placement: .desktop(number: 2))]))
        #expect(withDesktop1.defaultSpaceID(displayUUID: Self.uuidA) == Self.uuidA + "#0")

        // Desktop 1 empty: the Space with the most windows wins (Desktop 2 with two windows beats the full-screen one).
        let busierDesktop2 = ProfileSpaceIndex(profile: Self.profile(
            displays: [display], spaces: spaces,
            windows: [Self.window(2, placement: .desktop(number: 2)), Self.window(3, placement: .desktop(number: 2)),
                      Self.window(4, placement: .fullScreen(position: 2), fullScreen: true)]))
        #expect(busierDesktop2.defaultSpaceID(displayUUID: Self.uuidA) == Self.uuidA + "#1")

        // Desktop 1 empty and the full-screen Space has the most windows.
        let fullScreenWins = ProfileSpaceIndex(profile: Self.profile(
            displays: [display], spaces: [Self.desktopSpace(Self.uuidA, 0, 1),
                                          SpaceSnapshot(displayUUID: Self.uuidA, position: 1, kind: .fullScreen,
                                                        fullScreenWindowIDs: [Self.wid(4), Self.wid(5)])],
            windows: [Self.window(4, placement: .fullScreen(position: 1), fullScreen: true),
                      Self.window(5, placement: .fullScreen(position: 1), z: 1, fullScreen: true),
                      Self.window(2, placement: .desktop(number: 1), minimized: true)]))
        #expect(fullScreenWins.defaultSpaceID(displayUUID: Self.uuidA) == Self.uuidA + "#1")

        // Everything empty: Desktop 1.
        let empty = ProfileSpaceIndex(profile: Self.profile(displays: [display], spaces: spaces, windows: []))
        #expect(empty.defaultSpaceID(displayUUID: Self.uuidA) == Self.uuidA + "#0")

        // The layout uses that default when no selection is given.
        let busierProfile = Self.profile(
            displays: [display], spaces: spaces,
            windows: [Self.window(2, placement: .desktop(number: 2)), Self.window(3, placement: .desktop(number: 2)),
                      Self.window(4, placement: .fullScreen(position: 2), fullScreen: true)])
        let layout = ProfileMapLayout.make(profile: busierProfile, index: ProfileSpaceIndex(profile: busierProfile),
                                           viewport: Self.viewport)
        #expect(layout.thumbnails.first { $0.isSelected }?.id == Self.uuidA + "#1")
        #expect(layout.windows.count == 2)
    }

    // MARK: Layout

    @Test func sideBySideMonitorsKeepTheirArrangement() {
        let p = Self.profile(
            displays: [Self.display(Self.uuidA, CGRect(x: 0, y: 0, width: 1920, height: 1080), main: true),
                       Self.display(Self.uuidB, CGRect(x: 1920, y: 0, width: 1920, height: 1080))],
            windows: [])
        let layout = ProfileMapLayout.make(profile: p, index: ProfileSpaceIndex(profile: p), viewport: Self.viewport)
        let a = layout.monitors[0].frame
        let b = layout.monitors[1].frame

        #expect(a.minX < b.minX)
        #expect(a.maxX <= b.minX)
        #expect(Self.near(a.minY, b.minY))
        #expect(Self.near(a.height, b.height))
        // Touching monitors keep a visible gap.
        #expect(b.minX - a.maxX >= ProfileMapLayout.monitorGap - 0.01)
        #expect(layout.canvasSize.width >= Self.viewport.width)
    }

    @Test func stackedMonitorsKeepTheirArrangement() {
        let p = Self.profile(
            displays: [Self.display(Self.uuidA, CGRect(x: 0, y: 0, width: 1920, height: 1080), main: true),
                       Self.display(Self.uuidB, CGRect(x: 0, y: 1080, width: 1920, height: 1080))],
            windows: [])
        let layout = ProfileMapLayout.make(profile: p, index: ProfileSpaceIndex(profile: p), viewport: Self.viewport)
        let top = layout.monitors[0].frame
        let bottom = layout.monitors[1].frame

        #expect(top.minY < bottom.minY)
        #expect(top.maxY <= bottom.minY)
        #expect(Self.near(top.minX, bottom.minX))
        #expect(bottom.minY - top.maxY >= ProfileMapLayout.monitorGap - 0.01)
    }

    @Test func differentHeightsKeepVerticalOffset() {
        // A 2560x1440 monitor with a 1920x1080 monitor to its right, starting 360 pt lower (a quarter of A's height).
        let p = Self.profile(
            displays: [Self.display(Self.uuidA, CGRect(x: 0, y: 0, width: 2560, height: 1440), main: true),
                       Self.display(Self.uuidB, CGRect(x: 2560, y: 360, width: 1920, height: 1080))],
            windows: [])
        let layout = ProfileMapLayout.make(profile: p, index: ProfileSpaceIndex(profile: p), viewport: Self.viewport)
        let a = layout.monitors[0].frame
        let b = layout.monitors[1].frame

        #expect(b.minY > a.minY)
        // Both bottoms sit on y = 1440 in the real arrangement, so they line up too.
        #expect(Self.near(b.maxY, a.maxY))
        // The offset of the top edges is the same fraction of A's height as in the real arrangement.
        #expect(Self.near((b.minY - a.minY) / a.height, 360 / 1440, 0.005))
        #expect(Self.near(b.height / a.height, 1080 / 1440, 0.005))
    }

    @Test func tinyMonitorGetsMinimumSize() {
        let p = Self.profile(
            displays: [Self.display(Self.uuidA, CGRect(x: 0, y: 0, width: 3840, height: 2160), main: true),
                       Self.display(Self.uuidB, CGRect(x: 3840, y: 0, width: 320, height: 200))],
            windows: [])
        let layout = ProfileMapLayout.make(profile: p, index: ProfileSpaceIndex(profile: p), viewport: Self.viewport)
        let tiny = layout.monitors[1].frame

        #expect(tiny.width >= ProfileMapLayout.minTileSize)
        #expect(tiny.height >= ProfileMapLayout.minTileSize)
    }

    @Test func zoomScalesTheMap() {
        let p = Self.profile(
            displays: [Self.display(Self.uuidA, CGRect(x: 0, y: 0, width: 1920, height: 1080), main: true)],
            windows: [])
        let index = ProfileSpaceIndex(profile: p)
        let fit = ProfileMapLayout.make(profile: p, index: index, viewport: Self.viewport, zoom: 1)
        let half = ProfileMapLayout.make(profile: p, index: index, viewport: Self.viewport, zoom: 0.5)
        let double = ProfileMapLayout.make(profile: p, index: index, viewport: Self.viewport, zoom: 2.0)

        #expect(Self.near(half.monitors[0].frame.width, fit.monitors[0].frame.width / 2, 0.5))
        #expect(Self.near(double.monitors[0].frame.width, fit.monitors[0].frame.width * 2, 0.5))
        #expect(Self.near(double.monitors[0].frame.height, fit.monitors[0].frame.height * 2, 0.5))
        // Zoomed in past the viewport, so the canvas grows and scrolls.
        #expect(double.canvasSize.width > Self.viewport.width)
        #expect(fit.zoom == 1)
        #expect(half.zoom == 0.5)
        // Out-of-range zoom is clamped to 50...200 %.
        #expect(ProfileMapLayout.make(profile: p, index: index, viewport: Self.viewport, zoom: 10).zoom == 2.0)
        #expect(ProfileMapLayout.make(profile: p, index: index, viewport: Self.viewport, zoom: 0.01).zoom == 0.5)
    }

    @Test func windowRectUsesRelativeFrameInsideContentRect() {
        let p = Self.profile(
            displays: [Self.display(Self.uuidA, CGRect(x: 0, y: 0, width: 1920, height: 1080), main: true)],
            spaces: [Self.desktopSpace(Self.uuidA, 0, 1)],
            windows: [Self.window(1, "Safari", placement: .desktop(number: 1),
                                  relative: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))])
        let index = ProfileSpaceIndex(profile: p)
        let layout = ProfileMapLayout.make(profile: p, index: index, viewport: Self.viewport)
        let content = layout.monitors[0].contentRect
        let rect = layout.windows[0].rect

        #expect(Self.near(rect.minX, content.midX))
        #expect(Self.near(rect.width, content.width / 2))
        #expect(Self.near(rect.minY, content.minY))
        #expect(Self.near(rect.height, content.height))
        #expect(content.contains(CGPoint(x: rect.midX, y: rect.midY)))
    }

    @Test func contentRectIsTheVisibleFrameNotTheWholeMonitor() {
        // The menu bar takes 25 pt at the top, so the content rect starts lower than the tile.
        let p = Self.profile(
            displays: [Self.display(Self.uuidA, CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                    visible: CGRect(x: 0, y: 25, width: 1920, height: 1055), main: true)],
            windows: [])
        let layout = ProfileMapLayout.make(profile: p, index: ProfileSpaceIndex(profile: p), viewport: Self.viewport)
        let monitor = layout.monitors[0]

        #expect(monitor.contentRect.minY > monitor.frame.minY)
        #expect(Self.near(monitor.contentRect.maxY, monitor.frame.maxY))
        #expect(Self.near(monitor.contentRect.width, monitor.frame.width))
    }

    @Test func hitTestReturnsTopmostWindowByZIndex() {
        let p = Self.profile(
            displays: [Self.display(Self.uuidA, CGRect(x: 0, y: 0, width: 1920, height: 1080), main: true)],
            spaces: [Self.desktopSpace(Self.uuidA, 0, 1)],
            windows: [Self.window(1, "Back", placement: .desktop(number: 1),
                                  relative: CGRect(x: 0, y: 0, width: 1, height: 1), z: 3),
                      Self.window(2, "Front", placement: .desktop(number: 1),
                                  relative: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), z: 0),
                      Self.window(3, "Middle", placement: .desktop(number: 1),
                                  relative: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), z: 1)])
        let index = ProfileSpaceIndex(profile: p)
        let layout = ProfileMapLayout.make(profile: p, index: index, viewport: Self.viewport)
        let center = CGPoint(x: layout.windows[0].rect.midX, y: layout.windows[0].rect.midY)

        // Front (zIndex 0) wins over Middle (1) and Back (3), whatever the drawing order.
        if case .window(let windowID, _) = layout.hitTest(center) {
            #expect(windowID == Self.wid(2))
        } else {
            Issue.record("Expected a window hit at the centre")
        }

        // A point on the monitor but outside every window hits the monitor.
        let corner = CGPoint(x: layout.monitors[0].frame.minX + 2, y: layout.monitors[0].frame.minY + 2)
        #expect(layout.hitTest(corner) == .monitor(displayUUID: Self.uuidA))

        // A point off the canvas hits nothing.
        #expect(layout.hitTest(CGPoint(x: -500, y: -500)) == nil)
    }

    @Test func emptyProfileGivesEmptyLayout() {
        let p = Self.profile(displays: [], windows: [])
        let layout = ProfileMapLayout.make(profile: p, index: ProfileSpaceIndex(profile: p), viewport: Self.viewport)

        #expect(layout.monitors.isEmpty)
        #expect(layout.windows.isEmpty)
        #expect(layout.canvasSize == Self.viewport)
    }
}
