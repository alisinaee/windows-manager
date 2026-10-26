import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// PM8: plain-text profile map. Golden strings pin the layout for three fixtures, so map geometry is
/// checked without launching the app (docs/PLAN-profile-maps.md, section E, PM8).
@Suite struct ProfileMapTextTests {
    static let main = "PMT00000-0000-4000-8000-00000000000A"
    static let second = "PMT00000-0000-4000-8000-00000000000B"

    static func wid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", n))!
    }

    static func display(_ uuid: String, name: String, _ frame: CGRect, main: Bool) -> DisplayIdentity {
        DisplayIdentity(uuid: uuid, name: name, frame: frame,
                        visibleFrame: CGRect(x: frame.minX, y: frame.minY + 25, width: frame.width, height: frame.height - 25),
                        isMain: main, isBuiltIn: main)
    }

    static func window(_ n: Int, _ app: String, title: String? = nil, display: String, frame: CGRect,
                       relative: CGRect, placement: SpacePlacement, minimized: Bool = false,
                       z: Int = 0) -> WindowSnapshot {
        WindowSnapshot(id: wid(n), app: AppRef(bundleID: nil, name: app), title: title, indexInApp: 0,
                       displayUUID: display, frame: frame, relativeFrame: relative, placement: placement,
                       isMinimized: minimized, zIndex: z)
    }

    static func profile(name: String, displays: [DisplayIdentity] = [], spaces: [SpaceSnapshot] = [],
                        windows: [WindowSnapshot] = [], stageManager: Bool? = nil) -> Profile {
        Profile(name: name, createdAt: Date(timeIntervalSince1970: 0), monitorSetKey: "fixture",
                displays: displays, spaces: spaces, windows: windows, stageManagerOn: stageManager)
    }

    /// One 1440x900 monitor, Desktop 1 with Safari on the left half and Xcode on the lower right quarter.
    static var oneMonitor: Profile {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        return profile(
            name: "Solo",
            displays: [display(main, name: "Studio Display", screen, main: true)],
            spaces: [SpaceSnapshot(displayUUID: main, position: 0, kind: .desktop, desktopNumber: 1)],
            windows: [
                window(1, "Safari", title: "Inbox", display: main, frame: CGRect(x: 0, y: 0, width: 720, height: 900),
                       relative: CGRect(x: 0, y: 0, width: 0.5, height: 1), placement: .desktop(number: 1)),
                window(2, "Xcode", display: main, frame: CGRect(x: 720, y: 225, width: 720, height: 450),
                       relative: CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5), placement: .desktop(number: 1), z: 1),
            ],
            stageManager: false)
    }

    /// A main 1440x900 monitor with Desktop 1 (Safari), and a 2560x1440 secondary monitor to its right with a
    /// full-screen Keynote Space first and Desktop 1 (Slack) second.
    static var twoMonitors: Profile {
        let mainScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let side = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        return profile(
            name: "Work",
            displays: [display(main, name: "Studio Display", mainScreen, main: true),
                       display(second, name: "DELL U2723", side, main: false)],
            spaces: [SpaceSnapshot(displayUUID: main, position: 0, kind: .desktop, desktopNumber: 1),
                     SpaceSnapshot(displayUUID: second, position: 0, kind: .fullScreen, fullScreenWindowIDs: [wid(3)]),
                     SpaceSnapshot(displayUUID: second, position: 1, kind: .desktop, desktopNumber: 1)],
            windows: [
                window(1, "Safari", title: "Inbox", display: main, frame: CGRect(x: 0, y: 0, width: 720, height: 900),
                       relative: CGRect(x: 0, y: 0, width: 0.5, height: 1), placement: .desktop(number: 1)),
                window(3, "Keynote", title: "Deck", display: second, frame: side,
                       relative: CGRect(x: 0, y: 0, width: 1, height: 1), placement: .fullScreen(position: 0)),
                window(4, "Slack", display: second, frame: CGRect(x: 1440, y: 0, width: 1024, height: 1440),
                       relative: CGRect(x: 0, y: 0, width: 0.4, height: 1), placement: .desktop(number: 1), z: 1),
            ],
            stageManager: false)
    }

    static var empty: Profile {
        profile(name: "Empty")
    }

    static func render(_ profile: Profile, width: Int = ProfileMapText.defaultWidth) -> String {
        ProfileMapText.render(profile: profile, width: width)
    }

    // MARK: Golden strings

    // Expected text was taken from the renderer's output and checked by hand against the fixtures.
    @Test func oneMonitorGolden() {
        let expected = """
        Profile: Solo
        Stage Manager: off at capture

        Display: Studio Display, 1440x900 pt, main
          Desktop 1 (2 windows)
            [1] Safari - "Inbox"  (0%,0% 50%x100%)
            [2] Xcode  (50%,25% 50%x50%)
            +----------------------------------------------------------+
            |+---------------------------+                             |
            ||                           |                             |
            ||                           |                             |
            ||                           |                             |
            ||                           |+---------------------------+|
            ||                           ||                           ||
            ||                           ||                           ||
            ||                           ||                           ||
            ||             1             ||             2             ||
            ||                           ||                           ||
            ||                           ||                           ||
            ||                           ||                           ||
            ||                           |+---------------------------+|
            ||                           |                             |
            ||                           |                             |
            ||                           |                             |
            |+---------------------------+                             |
            +----------------------------------------------------------+
            Legend: digits and letters are the windows listed above; + - | draw each window's box

        Summary: 1 display | 1 Space | 2 windows | 0 minimized
        """
        #expect(Self.render(Self.oneMonitor) == expected + "\n")
    }

    @Test func twoMonitorsGolden() {
        let expected = """
        Profile: Work
        Stage Manager: off at capture

        Display: Studio Display, 1440x900 pt, main
          Desktop 1 (1 window)
            [1] Safari - "Inbox"  (0%,0% 50%x100%)
            +----------------------------------------------------------+
            |+---------------------------+                             |
            ||                           |                             |
            ||                           |                             |
            ||                           |                             |
            ||                           |                             |
            ||                           |                             |
            ||                           |                             |
            ||                           |                             |
            ||             1             |                             |
            ||                           |                             |
            ||                           |                             |
            ||                           |                             |
            ||                           |                             |
            ||                           |                             |
            ||                           |                             |
            ||                           |                             |
            |+---------------------------+                             |
            +----------------------------------------------------------+
            Legend: digits and letters are the windows listed above; + - | draw each window's box

        Display: DELL U2723, 2560x1440 pt
          Full screen: Keynote (1 window)
            [1] Keynote - "Deck"  (0%,0% 100%x100%)
            +----------------------------------------------------------+
            |+--------------------------------------------------------+|
            ||                                                        ||
            ||                                                        ||
            ||                                                        ||
            ||                                                        ||
            ||                                                        ||
            ||                                                        ||
            ||                           1                            ||
            ||                                                        ||
            ||                                                        ||
            ||                                                        ||
            ||                                                        ||
            ||                                                        ||
            ||                                                        ||
            |+--------------------------------------------------------+|
            +----------------------------------------------------------+
            Legend: digits and letters are the windows listed above; + - | draw each window's box
          Desktop 1 (1 window)
            [1] Slack  (0%,0% 40%x100%)
            +----------------------------------------------------------+
            |+----------------------+                                  |
            ||                      |                                  |
            ||                      |                                  |
            ||                      |                                  |
            ||                      |                                  |
            ||                      |                                  |
            ||                      |                                  |
            ||          1           |                                  |
            ||                      |                                  |
            ||                      |                                  |
            ||                      |                                  |
            ||                      |                                  |
            ||                      |                                  |
            ||                      |                                  |
            |+----------------------+                                  |
            +----------------------------------------------------------+
            Legend: digits and letters are the windows listed above; + - | draw each window's box

        Summary: 2 displays | 3 Spaces | 3 windows | 0 minimized
        """
        #expect(Self.render(Self.twoMonitors) == expected + "\n")
    }

    @Test func emptyGolden() {
        let expected = """
        Profile: Empty
        Stage Manager: unknown

        No displays and no windows.

        Summary: 0 displays | 0 Spaces | 0 windows | 0 minimized
        """
        #expect(Self.render(Self.empty) == expected + "\n")
    }
}
