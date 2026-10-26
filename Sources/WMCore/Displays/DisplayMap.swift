import AppKit
import CoreGraphics
import Foundation

// Knows the monitors that are connected, converts coordinates, and maps saved monitors and frames onto
// the monitors connected now.
//
// The approach follows monitor-glue (MIT, https://github.com/erango/monitor-glue): monitors are keyed by
// their hardware UUID, frames are stored relative to the monitor they were on, and a restore is triggered
// on connect, wake and unlock (see DisplayWatcher). The code is our own.
//
// Every frame in this file uses global top-left coordinates: the origin is the top-left corner of the main
// display and y grows downward. That is the space the Accessibility API and CGWindowList use. NSScreen uses
// global bottom-left coordinates instead; `toTopLeft` / `toBottomLeft` convert between the two.

public enum DisplayMap {
    // MARK: Live displays

    /// Every connected display, main display first (NSScreen order). Frames are in global top-left coordinates.
    public static func current() -> [DisplayIdentity] {
        let mainID = CGMainDisplayID()
        let mainHeight = mainDisplayHeight()
        var result: [DisplayIdentity] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            result.append(DisplayIdentity(
                uuid: uuidString(for: displayID) ?? "display-\(displayID)",
                name: screen.localizedName,
                vendorID: CGDisplayVendorNumber(displayID),
                modelID: CGDisplayModelNumber(displayID),
                serial: CGDisplaySerialNumber(displayID),
                frame: toTopLeft(screen.frame, mainHeight: mainHeight),
                visibleFrame: toTopLeft(screen.visibleFrame, mainHeight: mainHeight),
                isMain: displayID == mainID,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                scale: Double(screen.backingScaleFactor)
            ))
        }
        return result
    }

    /// The CGDirectDisplayID of the connected display with this UUID (case-insensitive), or nil when it is not connected.
    public static func cgDisplayID(for uuid: String) -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        for id in ids.prefix(Int(count)) {
            if let text = uuidString(for: id), text.caseInsensitiveCompare(uuid) == .orderedSame { return id }
        }
        return nil
    }

    /// CGDisplayCreateUUIDFromDisplayID as an upper-case string.
    static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return (CFUUIDCreateString(nil, uuid) as String?)?.uppercased()
    }

    // MARK: Coordinates

    /// Height of the main display in points. Both coordinate spaces are anchored to the main display.
    public static func mainDisplayHeight() -> CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    /// Converts a rect from NSScreen / AppKit global bottom-left coordinates to global top-left coordinates.
    /// `mainHeight` defaults to the height of the main display; pass it to convert without touching the system.
    public static func toTopLeft(_ rect: CGRect, mainHeight: CGFloat? = nil) -> CGRect {
        let height = mainHeight ?? mainDisplayHeight()
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts a rect from global top-left coordinates to AppKit global bottom-left coordinates.
    public static func toBottomLeft(_ rect: CGRect, mainHeight: CGFloat? = nil) -> CGRect {
        // The flip is its own inverse.
        toTopLeft(rect, mainHeight: mainHeight)
    }

    public static func toTopLeft(_ point: CGPoint, mainHeight: CGFloat? = nil) -> CGPoint {
        CGPoint(x: point.x, y: (mainHeight ?? mainDisplayHeight()) - point.y)
    }

    public static func toBottomLeft(_ point: CGPoint, mainHeight: CGFloat? = nil) -> CGPoint {
        toTopLeft(point, mainHeight: mainHeight)
    }

    // MARK: Monitor set

    /// A key for the set of connected monitors: the upper-case UUIDs, sorted, joined with "+".
    /// It does not depend on the order of the list or on where the monitors sit, so a profile saved for
    /// one monitor set can be found again when the same monitors come back.
    public static func monitorSetKey(_ displays: [DisplayIdentity]) -> String {
        displays.map { $0.uuid.uppercased() }.sorted().joined(separator: "+")
    }

    // MARK: Matching

    /// Maps each saved display (by its uuid) to the live display it should be restored onto.
    ///
    /// Matching goes from the strongest signal to the weakest, and every step only uses displays that
    /// are still free, so two saved displays never share one live display while a free one is left:
    ///  1. same UUID;
    ///  2. same vendor + model + serial (when the vendor or model is known);
    ///  3. same vendor + model and the same size;
    ///  4. the same size;
    ///  5. the same role: built-in with built-in, then main with main;
    ///  6. last resort: the live main display if it is free, else the nearest free display. When there
    ///     are more saved than live displays, the rest share the live main display.
    /// Where several live displays fit equally well (two identical monitors), the one whose top-left
    /// corner is closest to the saved one wins.
    /// Saved displays that cannot be placed at all (no live displays) are missing from the result.
    public static func match(saved: [DisplayIdentity], current: [DisplayIdentity]) -> [String: DisplayIdentity] {
        guard !saved.isEmpty, !current.isEmpty else { return [:] }

        func sameUUID(_ a: DisplayIdentity, _ b: DisplayIdentity) -> Bool {
            a.uuid.caseInsensitiveCompare(b.uuid) == .orderedSame
        }
        func hasHardwareID(_ a: DisplayIdentity) -> Bool { a.vendorID != 0 || a.modelID != 0 }
        func sameModel(_ a: DisplayIdentity, _ b: DisplayIdentity) -> Bool {
            hasHardwareID(a) && a.vendorID == b.vendorID && a.modelID == b.modelID
        }
        func sameSize(_ a: DisplayIdentity, _ b: DisplayIdentity) -> Bool {
            abs(a.frame.width - b.frame.width) < 0.5 && abs(a.frame.height - b.frame.height) < 0.5
        }

        let levels: [(DisplayIdentity, DisplayIdentity) -> Bool] = [
            { sameUUID($0, $1) },
            { sameModel($0, $1) && $0.serial == $1.serial },
            { sameModel($0, $1) && sameSize($0, $1) },
            { sameSize($0, $1) },
            { $0.isBuiltIn && $1.isBuiltIn },
            { $0.isMain && $1.isMain },
        ]

        var liveForSaved: [Int: Int] = [:]
        var usedLive = Set<Int>()

        for level in levels {
            var pairs: [(saved: Int, live: Int, distance: Double)] = []
            for (si, s) in saved.enumerated() where liveForSaved[si] == nil {
                for (li, l) in current.enumerated() where !usedLive.contains(li) && level(s, l) {
                    pairs.append((si, li, distance(s.frame.origin, l.frame.origin)))
                }
            }
            pairs.sort { ($0.distance, $0.saved, $0.live) < ($1.distance, $1.saved, $1.live) }
            for pair in pairs where liveForSaved[pair.saved] == nil && !usedLive.contains(pair.live) {
                liveForSaved[pair.saved] = pair.live
                usedLive.insert(pair.live)
            }
        }

        // Last resort. The saved main display goes first so it gets the live main display.
        let mainIndex = current.firstIndex(where: { $0.isMain }) ?? 0
        let leftovers = saved.indices.filter { liveForSaved[$0] == nil }
            .sorted { (saved[$0].isMain ? 0 : 1, $0) < (saved[$1].isMain ? 0 : 1, $1) }
        for si in leftovers {
            let free = current.indices.filter { !usedLive.contains($0) }
            let target: Int
            if !usedLive.contains(mainIndex) {
                target = mainIndex
            } else if let nearest = free.min(by: {
                distance(saved[si].frame.origin, current[$0].frame.origin)
                    < distance(saved[si].frame.origin, current[$1].frame.origin)
            }) {
                target = nearest
            } else {
                target = mainIndex // more saved displays than live ones: share the main display
            }
            liveForSaved[si] = target
            usedLive.insert(target)
        }

        var result: [String: DisplayIdentity] = [:]
        for (si, li) in liveForSaved { result[saved[si].uuid] = current[li] }
        return result
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: Frames

    /// Maps a window frame saved on display `saved` onto display `live`. All rects are global top-left.
    ///
    /// - The same display, or a display of the same size: the frame keeps its place relative to the
    ///   display's top-left corner (so it is unchanged when the display did not move) as long as it still
    ///   fits inside the live visible frame.
    /// - Otherwise the frame is placed proportionally inside the live visible frame. The size is kept when
    ///   it fits; if not, it is scaled by the ratio of the two visible frames. The free space around the
    ///   window is scaled too, so a window that touched the right edge still touches it.
    /// - The result is always clamped inside the live visible frame.
    public static func mapFrame(_ frame: CGRect, from saved: DisplayIdentity, to live: DisplayIdentity) -> CGRect {
        let target = live.visibleFrame
        guard target.width > 0, target.height > 0 else { return frame }

        let sameDisplay = saved.uuid.caseInsensitiveCompare(live.uuid) == .orderedSame
        let sameSize = abs(saved.frame.width - live.frame.width) < 0.5
            && abs(saved.frame.height - live.frame.height) < 0.5
        if sameDisplay || sameSize {
            let moved = frame.offsetBy(dx: live.frame.minX - saved.frame.minX, dy: live.frame.minY - saved.frame.minY)
            if fits(moved, in: target) { return moved }
        }

        // A saved display with no usable size cannot give a ratio; treat it as if it had the live size.
        var source = saved.visibleFrame.width > 0 && saved.visibleFrame.height > 0 ? saved.visibleFrame : saved.frame
        if source.width <= 0 || source.height <= 0 { source = target }

        var width = frame.width
        var height = frame.height
        if width > target.width + tolerance || height > target.height + tolerance {
            width = min(width * target.width / source.width, target.width)
            height = min(height * target.height / source.height, target.height)
        }

        let x = place(start: frame.minX, length: frame.width, in: (source.minX, source.width),
                      newLength: width, target: (target.minX, target.width))
        let y = place(start: frame.minY, length: frame.height, in: (source.minY, source.height),
                      newLength: height, target: (target.minY, target.height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Where a window starts on one axis: its share of the free space around it in the source, applied to
    /// the free space around the new size in the target, then clamped inside the target.
    private static func place(start: CGFloat, length: CGFloat, in source: (origin: CGFloat, length: CGFloat),
                              newLength: CGFloat, target: (origin: CGFloat, length: CGFloat)) -> CGFloat {
        let sourceFree = source.length - length
        let share = abs(sourceFree) > tolerance ? (start - source.origin) / sourceFree : 0
        let proposed = target.origin + share * (target.length - newLength)
        return max(target.origin, min(proposed, target.origin + target.length - newLength))
    }

    private static let tolerance: CGFloat = 0.5

    private static func fits(_ rect: CGRect, in container: CGRect) -> Bool {
        rect.minX >= container.minX - tolerance && rect.maxX <= container.maxX + tolerance
            && rect.minY >= container.minY - tolerance && rect.maxY <= container.maxY + tolerance
    }

    /// The display that holds most of `frame` (largest overlap with the whole display frame). A frame that
    /// touches no display goes to the nearest one; ties go to the display closer to the frame's center.
    /// Nil only when `displays` is empty.
    public static func display(containing frame: CGRect, in displays: [DisplayIdentity]) -> DisplayIdentity? {
        guard !displays.isEmpty else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)

        func overlap(_ display: DisplayIdentity) -> CGFloat {
            let common = display.frame.intersection(frame)
            return common.isNull ? 0 : common.width * common.height
        }
        func centerDistance(_ display: DisplayIdentity) -> Double {
            distance(center, CGPoint(x: display.frame.midX, y: display.frame.midY))
        }
        /// Distance from a point to the nearest point of the display's rect (0 when inside).
        func edgeDistance(_ display: DisplayIdentity) -> Double {
            let dx = max(display.frame.minX - center.x, 0, center.x - display.frame.maxX)
            let dy = max(display.frame.minY - center.y, 0, center.y - display.frame.maxY)
            return Double((dx * dx + dy * dy).squareRoot())
        }

        let best = displays.map(overlap).max() ?? 0
        if best > 0 {
            return displays.filter { overlap($0) == best }.min { centerDistance($0) < centerDistance($1) }
        }
        return displays.min { (edgeDistance($0), centerDistance($0)) < (edgeDistance($1), centerDistance($1)) }
    }
}
