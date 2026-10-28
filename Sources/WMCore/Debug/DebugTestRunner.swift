import AppKit
import CoreGraphics
import Foundation

// Live challenge test runner (P6.70): scramble the real desktop, restore a fixture profile through RestoreEngine,
// then verify against the live windows. Every event is also appended to ~/Library/Logs/Windows Manager/debug-tests.log.

public final class DebugTestRunner: @unchecked Sendable {
    let store: ProfileStore

    public init(store: ProfileStore) { self.store = store }

    static let textEdit = "com.apple.TextEdit"
    static let calculator = "com.apple.calculator"
    static let notes = "com.apple.Notes"
    static let finder = "com.apple.finder"
    static let safari = "com.apple.Safari"
    static let fixtureBundles: Set<String> = [textEdit, calculator, notes, finder, safari]

    // MARK: Fixtures

    @discardableResult
    public static func installFixtureProfiles(into store: ProfileStore) throws -> [Profile] {
        let displays = DisplayMap.current()
        guard let main = displays.first(where: \.isMain) ?? displays.first else {
            throw NSError(domain: "DebugTestRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"])
        }
        let vf = main.visibleFrame
        let top = vf.minY  // first usable y below the menu bar on this display
        func snap(_ bundle: String, _ name: String, _ frame: CGRect, desktop: Int?, title: String? = nil,
                  match: TitleMatch = .any, index: Int = 0) -> WindowSnapshot {
            let rel = CGRect(x: (frame.minX - vf.minX) / vf.width, y: (frame.minY - vf.minY) / vf.height,
                             width: frame.width / vf.width, height: frame.height / vf.height)
            return WindowSnapshot(app: AppRef(bundleID: bundle, name: name), title: title, titleMatch: match,
                                  indexInApp: index, displayUUID: main.uuid, frame: frame, relativeFrame: rel,
                                  placement: desktop.map { .desktop(number: $0) } ?? .allDesktops, zIndex: index)
        }
        func spaces(_ n: Int) -> [SpaceSnapshot] {
            (1...n).map { SpaceSnapshot(displayUUID: main.uuid, position: $0 - 1, kind: .desktop, desktopNumber: $0) }
        }
        let key = DisplayMap.monitorSetKey(displays)
        let work = Profile(name: "Challenge Work", monitorSetKey: key, displays: displays, spaces: spaces(3), windows: [
            snap(textEdit, "TextEdit", CGRect(x: 0, y: top, width: 800, height: 600), desktop: 1),
            snap(calculator, "Calculator", CGRect(x: vf.maxX - 230, y: top, width: 230, height: 408), desktop: 1),
            snap(notes, "Notes", CGRect(x: 100, y: 100, width: 1000, height: 700), desktop: 2),
            snap(finder, "Finder", CGRect(x: 900, y: 400, width: 700, height: 500), desktop: 2),
            snap(safari, "Safari", CGRect(x: 0, y: top, width: 1200, height: 800), desktop: 3),
            snap(textEdit, "TextEdit", CGRect(x: 1250, y: top, width: 600, height: 500), desktop: 3, index: 1),
        ])
        let halfW = (vf.width / 2).rounded(.down)
        let home = Profile(name: "Home", monitorSetKey: key, displays: displays, spaces: spaces(2), windows: [
            snap(finder, "Finder", CGRect(x: vf.minX, y: vf.minY, width: halfW, height: vf.height), desktop: 1),
            snap(notes, "Notes", CGRect(x: vf.minX + halfW, y: vf.minY, width: halfW, height: vf.height), desktop: 1),
            snap(safari, "Safari", vf, desktop: 2),
            snap(calculator, "Calculator", CGRect(x: vf.maxX - 230, y: vf.minY + 40, width: 230, height: 408),
                 desktop: nil),
        ])
        let dup = Profile(name: "Challenge Dup", monitorSetKey: key, displays: displays, spaces: spaces(1), windows: [
            snap(textEdit, "TextEdit", CGRect(x: 0, y: top, width: 600, height: 500), desktop: 1,
                 title: "Untitled", match: .exact("Untitled"), index: 0),
            snap(textEdit, "TextEdit", CGRect(x: 700, y: top, width: 600, height: 500), desktop: 1,
                 title: "Untitled", match: .exact("Untitled"), index: 1),
        ])
        // Reuse the ids of already installed fixtures so reinstalling replaces instead of duplicating.
        var saved: [Profile] = []
        let existing = store.list()
        for var p in [work, home, dup] {
            if let old = existing.first(where: { $0.name == p.name }) { p.id = old.id }
            saved.append(try store.save(p))
        }
        return saved
    }
}
