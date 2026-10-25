import AppKit
import ApplicationServices
import Foundation

// Probes for "Virtual desktops" mode, part 2: parking a window in a screen corner.
// Idea and corner arithmetic follow AeroSpace (MIT, https://github.com/nikitabobko/AeroSpace, see
// hideInCorner in Sources/AppBundle/tree/MacWindow.swift): macOS refuses to put a window completely off
// every screen, so a window is "hidden" by moving its top-left point to the bottom-right (or its right
// edge to the bottom-left) corner of the screen, so that 1 px stays visible. Only the position is set; the
// size is never touched. The code here is our own.

/// Which screen corner a window is parked in.
public enum ParkCorner: String, Codable, CaseIterable {
    case bottomRight = "br"
    case bottomLeft = "bl"
}

public enum CornerParkerError: Error, LocalizedError, Equatable {
    case noFrame
    case noScreens

    public var errorDescription: String? {
        switch self {
        case .noFrame: return "the window's position or size could not be read through Accessibility"
        case .noScreens: return "no screens were found"
        }
    }
}

/// What one park-and-restore run found.
public struct ParkReport: Codable, Equatable {
    public var windowID: UInt32 = 0
    public var corner: ParkCorner = .bottomRight
    public var originalFrame: CGRect = .zero
    /// Screen frame the window was parked on (Accessibility coordinates).
    public var screenFrame: CGRect = .zero
    public var screenCount = 0
    public var requestedOrigin: CGPoint = .zero

    public var setPositionAccepted = false
    public var setPositionCallSeconds: TimeInterval = 0
    /// AX position read right after the set call.
    public var positionRightAfterCall: CGPoint?
    /// Seconds after the set call until AX and CGWindowList both showed the new position; nil = never.
    public var settledAfter: TimeInterval?
    /// Where macOS actually put the window (AX), after settling.
    public var actualFrameAX: CGRect?
    /// The same window as CGWindowList reports it.
    public var actualFrameCG: CGRect?
    /// Actual minus requested origin; (0, 0) means macOS let the window go exactly where it was sent.
    public var offsetFromRequested: CGPoint?
    /// macOS changed the window size while parking.
    public var sizeChanged = false
    /// Part of the window that is inside its own screen (width, height in points).
    public var visibleOnScreen: CGSize?
    /// Part of the window that shows on another screen (it should not be on any).
    public var overlapsOtherScreen = false
    /// kCGWindowIsOnscreen of the parked window; nil when CGWindowList did not list it.
    public var cgIsOnScreenWhileParked: Bool?

    public var restoreAccepted = false
    public var restoreCallSeconds: TimeInterval = 0
    public var restoredAfter: TimeInterval?
    public var restoredFrame: CGRect?
    public var restoredExactly = false
    /// The first restore did not give the exact frame, so size-position-size was tried.
    public var neededSecondRestore = false
    public var interrupted = false
    public var notes: [String] = []

    public init() {}
}

public enum CornerParker {
    /// How many pixels of the window stay on screen.
    public static let visiblePixels: CGFloat = 1

    // MARK: Pure geometry

    /// Top-left point to move a window of `windowSize` to so that only `visiblePixels` of it stay inside
    /// `screenFrame`. All values use the same coordinate space (Accessibility: origin top-left, y down).
    /// - bottomRight: the window's top-left corner sits 1 px inside the bottom-right corner.
    /// - bottomLeft: the window's top-right corner sits 1 px inside the bottom-left corner.
    public static func parkedOrigin(windowSize: CGSize, screenFrame: CGRect, corner: ParkCorner) -> CGPoint {
        switch corner {
        case .bottomRight:
            return CGPoint(x: screenFrame.maxX - visiblePixels, y: screenFrame.maxY - visiblePixels)
        case .bottomLeft:
            return CGPoint(x: screenFrame.minX - windowSize.width + visiblePixels,
                           y: screenFrame.maxY - visiblePixels)
        }
    }

    /// The whole frame of the window once parked.
    public static func parkedFrame(windowSize: CGSize, screenFrame: CGRect, corner: ParkCorner) -> CGRect {
        CGRect(origin: parkedOrigin(windowSize: windowSize, screenFrame: screenFrame, corner: corner),
               size: windowSize)
    }

    /// The corner whose parked window would show on the fewest other screens' pixels. With several
    /// displays, a window parked in a corner that touches a neighbour would be fully visible there.
    /// Bottom-right wins ties.
    public static func preferredCorner(windowSize: CGSize, screenFrame: CGRect, otherScreens: [CGRect]) -> ParkCorner {
        func overlap(_ corner: ParkCorner) -> CGFloat {
            let parked = parkedFrame(windowSize: windowSize, screenFrame: screenFrame, corner: corner)
            return otherScreens.reduce(0) { $0 + area(parked.intersection($1)) }
        }
        return overlap(.bottomLeft) < overlap(.bottomRight) ? .bottomLeft : .bottomRight
    }

    /// Index of the screen frame that holds most of `windowFrame`; with no overlap at all, the screen whose
    /// center is nearest to the window's center. Nil only when `screens` is empty.
    public static func screenIndex(containing windowFrame: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        var best = 0
        var bestArea: CGFloat = -1
        for (i, screen) in screens.enumerated() {
            let a = area(windowFrame.intersection(screen))
            if a > bestArea { bestArea = a; best = i }
        }
        if bestArea > 0 { return best }
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        func distance(_ screen: CGRect) -> CGFloat {
            hypot(center.x - screen.midX, center.y - screen.midY)
        }
        return screens.indices.min { distance(screens[$0]) < distance(screens[$1]) }
    }

    /// Width and height of the overlap of two rects (zero size when they do not overlap).
    public static func overlapSize(_ a: CGRect, _ b: CGRect) -> CGSize {
        let r = a.intersection(b)
        return r.isNull ? .zero : CGSize(width: max(0, r.width), height: max(0, r.height))
    }

    /// NSScreen frames use a bottom-left origin; Accessibility and CGWindowList use a top-left origin on
    /// the main display. `mainHeight` is the height of the main (menu bar) screen.
    public static func accessibilityFrame(fromCocoa frame: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Frames of all screens in Accessibility coordinates. Main screen first.
    public static func screenFrames() -> [CGRect] {
        let screens = NSScreen.screens
        guard let main = screens.first else { return [] }
        return screens.map { accessibilityFrame(fromCocoa: $0.frame, mainHeight: main.frame.height) }
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height)
    }

    private static func near(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 1) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    private static func near(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        near(a.origin, b.origin, tolerance: tolerance)
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    // MARK: Experiment

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func ms(_ seconds: TimeInterval) -> String { String(format: "%.0f ms", seconds * 1000) }

    /// Parks `window`, measures where macOS actually left it, and puts it back where it was.
    /// `corner` nil picks `preferredCorner`. The original frame is restored in every case once the window's
    /// frame has been read (including when `shouldAbort` fires), so this only throws before anything moved.
    /// Moves a real window: lab use only.
    public static func parkAndRestore(window: AXUIElement, windowID: UInt32, corner: ParkCorner?,
                                      timeout: TimeInterval = 2, pollInterval: TimeInterval = 0.02,
                                      shouldAbort: () -> Bool = { false },
                                      log: (String) -> Void = { _ in }) throws -> ParkReport {
        guard let original = AXWindows.frame(of: window) else { throw CornerParkerError.noFrame }
        let screens = screenFrames()
        guard let index = screenIndex(containing: original, screens: screens) else { throw CornerParkerError.noScreens }
        let screen = screens[index]
        let others = screens.enumerated().filter { $0.offset != index }.map(\.element)
        let chosen = corner ?? preferredCorner(windowSize: original.size, screenFrame: screen, otherScreens: others)

        var report = ParkReport()
        report.windowID = windowID
        report.corner = chosen
        report.originalFrame = original
        report.screenFrame = screen
        report.screenCount = screens.count
        let target = parkedOrigin(windowSize: original.size, screenFrame: screen, corner: chosen)
        report.requestedOrigin = target
        log("window \(windowID) is \(rectText(original)); screen \(index + 1) of \(screens.count) is \(rectText(screen)); "
            + "corner \(chosen.rawValue)\(corner == nil ? " (auto)" : "") -> top-left \(pointText(target))")

        // Park. From here on the window is moved, so the restore below must run.
        let start = uptime()
        report.setPositionAccepted = AXWindows.setPosition(target, of: window)
        report.setPositionCallSeconds = uptime() - start
        report.positionRightAfterCall = AXWindows.position(of: window)
        log("setPosition accepted=\(report.setPositionAccepted) in \(ms(report.setPositionCallSeconds)); "
            + "AX reads \(report.positionRightAfterCall.map(pointText) ?? "nothing") right after")

        // Wait until AX and the window server agree on a position that is not the old one.
        _ = waitUntil(timeout: timeout, interval: pollInterval) {
            if shouldAbort() { return true }
            guard let ax = AXWindows.position(of: window), let cg = WindowListReader.window(id: windowID) else { return false }
            let moved = !near(ax, original.origin)
            if moved && near(ax, cg.bounds.origin) {
                report.settledAfter = uptime() - start
                return true
            }
            return false
        }
        if shouldAbort() { report.interrupted = true }

        // Let a late correction (an app that pulls itself back) show up, then measure.
        if !report.interrupted {
            _ = waitUntil(timeout: 0.15, interval: pollInterval) { shouldAbort() }
        }
        let actualAX = AXWindows.frame(of: window)
        let actualCG = WindowListReader.window(id: windowID)
        report.actualFrameAX = actualAX
        report.actualFrameCG = actualCG?.bounds
        report.cgIsOnScreenWhileParked = actualCG?.isOnScreen
        if let actualAX {
            report.offsetFromRequested = CGPoint(x: actualAX.minX - target.x, y: actualAX.minY - target.y)
            report.sizeChanged = abs(actualAX.width - original.width) > 1 || abs(actualAX.height - original.height) > 1
            report.visibleOnScreen = overlapSize(actualAX, screen)
            report.overlapsOtherScreen = others.contains { area(actualAX.intersection($0)) > 0 }
            log("settled \(report.settledAfter.map(ms) ?? "never"); AX frame \(rectText(actualAX)); "
                + "CG frame \(actualCG.map { rectText($0.bounds) } ?? "not listed"); "
                + "visible on its screen \(Int(report.visibleOnScreen?.width ?? 0))x\(Int(report.visibleOnScreen?.height ?? 0)) px; "
                + "CG on-screen flag \(actualCG.map { String($0.isOnScreen) } ?? "n/a")")
        }
        if report.settledAfter == nil && !report.interrupted {
            report.notes.append("AX and CGWindowList never agreed on a new position within \(timeout) s")
        }
        if report.overlapsOtherScreen {
            report.notes.append("the parked window shows on another screen; pick the other corner")
        }

        restore(window: window, windowID: windowID, original: original, into: &report,
                timeout: timeout, pollInterval: pollInterval, log: log)
        return report
    }

    /// Puts the window back at `original` and measures how long that takes. Ignores `shouldAbort` on purpose.
    private static func restore(window: AXUIElement, windowID: UInt32, original: CGRect, into report: inout ParkReport,
                                timeout: TimeInterval, pollInterval: TimeInterval, log: (String) -> Void) {
        func matches() -> Bool {
            guard let frame = AXWindows.frame(of: window) else { return false }
            return near(frame, original)
        }

        let firstStart = uptime()
        report.restoreAccepted = AXWindows.setPosition(original.origin, of: window)
        if report.sizeChanged { AXWindows.setSize(original.size, of: window) }
        report.restoreCallSeconds = uptime() - firstStart
        report.restoredAfter = waitUntil(timeout: timeout, interval: pollInterval) { matches() }

        if report.restoredAfter == nil {
            // Second try: size, position, size (what AXWindows.setFrame does).
            report.neededSecondRestore = true
            log("restore: frame not back after the first try, trying size-position-size")
            let secondStart = uptime()
            AXWindows.setFrame(original, of: window)
            report.restoredAfter = waitUntil(timeout: timeout, interval: pollInterval) { matches() }
                .map { secondStart - firstStart + $0 }
        }
        report.restoredFrame = AXWindows.frame(of: window)
        report.restoredExactly = matches()
        log("restore accepted=\(report.restoreAccepted), call \(ms(report.restoreCallSeconds)), "
            + "back after \(report.restoredAfter.map(ms) ?? "never"); frame now \(report.restoredFrame.map(rectText) ?? "unknown")"
            + (report.restoredExactly ? " (exact)" : " (NOT the original frame)"))
        if !report.restoredExactly {
            report.notes.append("the window did not return to its original frame: wanted \(rectText(original))")
        }
    }

    // MARK: Text helpers

    static func pointText(_ p: CGPoint) -> String { "(\(Int(p.x.rounded())), \(Int(p.y.rounded())))" }

    static func rectText(_ r: CGRect) -> String {
        "\(Int(r.width.rounded()))x\(Int(r.height.rounded())) at (\(Int(r.minX.rounded())), \(Int(r.minY.rounded())))"
    }
}
