import CoreGraphics
import Foundation

// Pure edits of a profile draft for the Profile Studio Builder. Every operation works on a copy and only
// replaces `profile` when the result is still consistent (`Profile.validate()` reports nothing new), so a
// failed operation changes nothing. Desktop numbers, Space positions and window placements are renumbered
// together, so they never drift apart.

public enum ProfileDraftError: Error, Equatable, LocalizedError {
    case unknownDisplay(String)
    case unknownDesktop(display: String, number: Int)
    case unknownSpace(display: String, position: Int)
    case unknownWindow(UUID)
    case tooManyDesktops(max: Int)
    case lastDesktop
    case sameDesktop
    case notFullScreenSpace(position: Int)
    case windowAlreadyFullScreen(UUID)
    case windowNotOnDisplay(UUID)
    case invalidResult([String])

    public var errorDescription: String? {
        switch self {
        case .unknownDisplay(let id): return "The profile has no monitor \(id)."
        case .unknownDesktop(_, let n): return "There is no Desktop \(n) on that monitor."
        case .unknownSpace(_, let p): return "There is no Space at position \(p) on that monitor."
        case .unknownWindow: return "That window is not in the profile."
        case .tooManyDesktops(let max): return "A monitor can have at most \(max) Desktops."
        case .lastDesktop: return "The last Desktop of a monitor cannot be deleted."
        case .sameDesktop: return "Choose a different Desktop."
        case .notFullScreenSpace(let p): return "Space \(p) is not a full-screen Space."
        case .windowAlreadyFullScreen: return "That window already owns a full-screen Space."
        case .windowNotOnDisplay: return "That window is on another monitor."
        case .invalidResult(let problems): return "The change would make the profile inconsistent: \(problems.joined(separator: " "))"
        }
    }
}

/// What happens to the owner window(s) when a full-screen Space is removed.
public enum FullScreenRemoval: Equatable, Sendable {
    /// The windows stay, as normal windows on this Desktop number.
    case moveWindows(toDesktop: Int)
    /// The windows are deleted with the Space.
    case deleteWindows
}

public struct ProfileDraftEditor {
    /// Most Desktops one monitor can have in a draft.
    public static let maxDesktopsPerDisplay = 16

    public private(set) var profile: Profile

    public init(_ profile: Profile) {
        self.profile = profile
    }

    // MARK: Transactions

    private mutating func edit<T>(_ body: (inout Profile) throws -> T) throws -> T {
        var copy = profile
        let before = Set(profile.validate())
        let result = try body(&copy)
        let fresh = copy.validate().filter { !before.contains($0) }
        guard fresh.isEmpty else { throw ProfileDraftError.invalidResult(fresh) }
        profile = copy
        return result
    }

    // MARK: Space rebuilding

    /// One Space of a display while it is being edited. `oldPosition` is nil for a Space that is new.
    private struct Slot {
        var space: SpaceSnapshot
        var oldPosition: Int?
    }

    private static func slots(of profile: Profile, display: String) -> [Slot] {
        profile.spaces(onDisplay: display).map { Slot(space: $0, oldPosition: $0.position) }
    }

    /// Writes `slots` back as the Spaces of `display`: renumbers positions and Desktop numbers, and rewrites
    /// the `placement` of every window of that display that pointed at an old number or position.
    private static func commit(_ slots: [Slot], display: String, into profile: inout Profile) {
        var desktopMap: [Int: Int] = [:]
        var positionMap: [Int: Int] = [:]
        var newSpaces: [SpaceSnapshot] = []
        var desktopCount = 0
        for (index, slot) in slots.enumerated() {
            var space = slot.space
            space.position = index
            if space.kind == .desktop {
                desktopCount += 1
                if let old = slot.space.desktopNumber { desktopMap[old] = desktopCount }
                space.desktopNumber = desktopCount
            } else {
                space.desktopNumber = nil
            }
            if let old = slot.oldPosition { positionMap[old] = index }
            newSpaces.append(space)
        }
        profile.spaces.removeAll { $0.displayUUID == display }
        profile.spaces.append(contentsOf: newSpaces)
        let owners = Dictionary(newSpaces.filter { $0.kind == .fullScreen }
            .flatMap { space in space.fullScreenWindowIDs.map { ($0, space.position) } },
                                uniquingKeysWith: { first, _ in first })
        for index in profile.windows.indices where profile.windows[index].displayUUID == display {
            switch profile.windows[index].placement {
            case .desktop(let n):
                if let new = desktopMap[n] { profile.windows[index].placement = .desktop(number: new) }
            case .fullScreen(let p):
                if let new = positionMap[p] { profile.windows[index].placement = .fullScreen(position: new) }
            default: break
            }
            if let position = owners[profile.windows[index].id] {
                profile.windows[index].placement = .fullScreen(position: position)
            }
        }
    }

    private static func requireDisplay(_ uuid: String, in profile: Profile) throws -> DisplayIdentity {
        guard let display = profile.displays.first(where: { $0.uuid == uuid }) else {
            throw ProfileDraftError.unknownDisplay(uuid)
        }
        return display
    }

    private static func desktopSlotIndex(_ number: Int, in slots: [Slot], display: String) throws -> Int {
        guard let i = slots.firstIndex(where: { $0.space.kind == .desktop && $0.space.desktopNumber == number }) else {
            throw ProfileDraftError.unknownDesktop(display: display, number: number)
        }
        return i
    }

    // MARK: Frames

    private static func area(of display: DisplayIdentity) -> CGRect {
        let a = display.visibleFrame
        return a.width > 0 && a.height > 0 ? a : display.frame
    }

    /// Global frame for a frame given as fractions of the display's visible frame.
    public static func frame(forRelative r: CGRect, in display: DisplayIdentity) -> CGRect {
        let a = area(of: display)
        return CGRect(x: a.minX + r.minX * a.width, y: a.minY + r.minY * a.height,
                      width: r.width * a.width, height: r.height * a.height)
    }

    /// Frame as fractions of the display's visible frame.
    public static func relative(forFrame f: CGRect, in display: DisplayIdentity) -> CGRect {
        ProfileCapture.relativeFrame(of: f, in: display)
    }

    /// 50% x 70% centered, used when nothing says where a new window goes.
    public static let defaultRelativeFrame = CGRect(x: 0.25, y: 0.15, width: 0.5, height: 0.7)

    // MARK: Desktops

    /// Adds a Desktop to a monitor. Default: after the last Desktop (macOS keeps full-screen Spaces behind
    /// the Desktops). `atNumber` inserts it as that Desktop number (1...count+1) and shifts the others.
    /// Returns the new Desktop's number.
    @discardableResult
    public mutating func addDesktop(onDisplay uuid: String, atNumber: Int? = nil) throws -> Int {
        try edit { p in
            _ = try Self.requireDisplay(uuid, in: p)
            var slots = Self.slots(of: p, display: uuid)
            let desktops = slots.indices.filter { slots[$0].space.kind == .desktop }
            guard desktops.count < Self.maxDesktopsPerDisplay else {
                throw ProfileDraftError.tooManyDesktops(max: Self.maxDesktopsPerDisplay)
            }
            let number = min(max(atNumber ?? desktops.count + 1, 1), desktops.count + 1)
            let insertAt: Int
            if number <= desktops.count {
                insertAt = desktops[number - 1]
            } else if let last = desktops.last {
                insertAt = last + 1
            } else {
                insertAt = 0
            }
            slots.insert(Slot(space: SpaceSnapshot(displayUUID: uuid, position: insertAt, kind: .desktop,
                                                   desktopNumber: nil), oldPosition: nil), at: insertAt)
            Self.commit(slots, display: uuid, into: &p)
            return number
        }
    }

    /// Deletes Desktop `number`. Its windows move to Desktop `moveWindowsTo` (a number before the deletion),
    /// or are deleted when that is nil. The last Desktop of a monitor cannot be deleted.
    public mutating func deleteDesktop(onDisplay uuid: String, number: Int, moveWindowsTo target: Int? = nil) throws {
        try edit { p in
            _ = try Self.requireDisplay(uuid, in: p)
            var slots = Self.slots(of: p, display: uuid)
            let index = try Self.desktopSlotIndex(number, in: slots, display: uuid)
            guard slots.filter({ $0.space.kind == .desktop }).count > 1 else { throw ProfileDraftError.lastDesktop }
            if let target {
                guard target != number else { throw ProfileDraftError.sameDesktop }
                _ = try Self.desktopSlotIndex(target, in: slots, display: uuid)
            }
            let affected = p.windows.indices.filter {
                p.windows[$0].displayUUID == uuid && p.windows[$0].placement == .desktop(number: number)
            }
            if let target {
                for i in affected { p.windows[i].placement = .desktop(number: target) }
            } else {
                let ids = Set(affected.map { p.windows[$0].id })
                p.windows.removeAll { ids.contains($0.id) }
            }
            slots.remove(at: index)
            Self.commit(slots, display: uuid, into: &p)
        }
    }

    /// Moves Desktop `number` so that it becomes Desktop `newNumber`. Full-screen Spaces keep their slots.
    public mutating func moveDesktop(onDisplay uuid: String, number: Int, toNumber newNumber: Int) throws {
        try edit { p in
            _ = try Self.requireDisplay(uuid, in: p)
            var slots = Self.slots(of: p, display: uuid)
            let source = try Self.desktopSlotIndex(number, in: slots, display: uuid)
            let slotIndices = slots.indices.filter { slots[$0].space.kind == .desktop }
            guard let position = slotIndices.firstIndex(of: source) else {
                throw ProfileDraftError.unknownDesktop(display: uuid, number: number)
            }
            var desktops = slotIndices.map { slots[$0] }
            let moved = desktops.remove(at: position)
            desktops.insert(moved, at: min(max(newNumber, 1), desktops.count + 1) - 1)
            for (i, slotIndex) in slotIndices.enumerated() { slots[slotIndex] = desktops[i] }
            Self.commit(slots, display: uuid, into: &p)
        }
    }

    // MARK: Full-screen Spaces

    /// Adds a full-screen Space owned by `owners` (one window, or two for Split View). The owners become
    /// full-screen windows (`relativeFrame` 0,0,1,1). The Space goes after Space `afterPosition` (default:
    /// the end). Returns the Space's new position.
    @discardableResult
    public mutating func addFullScreenSpace(onDisplay uuid: String, owners: [UUID], afterPosition: Int? = nil) throws -> Int {
        try edit { p in
            let display = try Self.requireDisplay(uuid, in: p)
            for id in owners {
                guard let w = p.windows.first(where: { $0.id == id }) else { throw ProfileDraftError.unknownWindow(id) }
                guard w.displayUUID == uuid else { throw ProfileDraftError.windowNotOnDisplay(id) }
                if p.spaces.contains(where: { $0.fullScreenWindowIDs.contains(id) }) {
                    throw ProfileDraftError.windowAlreadyFullScreen(id)
                }
            }
            var slots = Self.slots(of: p, display: uuid)
            let insertAt: Int
            if let afterPosition {
                guard let i = slots.firstIndex(where: { $0.space.position == afterPosition }) else {
                    throw ProfileDraftError.unknownSpace(display: uuid, position: afterPosition)
                }
                insertAt = i + 1
            } else {
                insertAt = slots.count
            }
            slots.insert(Slot(space: SpaceSnapshot(displayUUID: uuid, position: insertAt, kind: .fullScreen,
                                                   fullScreenWindowIDs: owners), oldPosition: nil), at: insertAt)
            for id in owners {
                guard let i = p.windows.firstIndex(where: { $0.id == id }) else { continue }
                p.windows[i].isFullScreen = true
                p.windows[i].isMinimized = false
                p.windows[i].relativeFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
                p.windows[i].frame = Self.frame(forRelative: p.windows[i].relativeFrame, in: display)
                p.windows[i].zoneName = nil
            }
            Self.commit(slots, display: uuid, into: &p)
            return insertAt
        }
    }

    /// Makes one window full screen in a new full-screen Space after `afterPosition` (default: the end).
    @discardableResult
    public mutating func makeFullScreen(windowID: UUID, afterPosition: Int? = nil) throws -> Int {
        guard let w = profile.windows.first(where: { $0.id == windowID }) else {
            throw ProfileDraftError.unknownWindow(windowID)
        }
        return try addFullScreenSpace(onDisplay: w.displayUUID, owners: [windowID], afterPosition: afterPosition)
    }

    /// Moves the full-screen Space at `position` so it becomes the `newIndex`-th (0-based) full-screen Space
    /// of the monitor. Desktops keep their numbers and slots.
    public mutating func moveFullScreenSpace(onDisplay uuid: String, position: Int, toIndex newIndex: Int) throws {
        try edit { p in
            _ = try Self.requireDisplay(uuid, in: p)
            var slots = Self.slots(of: p, display: uuid)
            guard let at = slots.firstIndex(where: { $0.space.position == position }) else {
                throw ProfileDraftError.unknownSpace(display: uuid, position: position)
            }
            guard slots[at].space.kind == .fullScreen else { throw ProfileDraftError.notFullScreenSpace(position: position) }
            let slotIndices = slots.indices.filter { slots[$0].space.kind == .fullScreen }
            var group = slotIndices.map { slots[$0] }
            let moved = group.remove(at: slotIndices.firstIndex(of: at)!)
            group.insert(moved, at: min(max(newIndex, 0), group.count))
            for (i, slotIndex) in slotIndices.enumerated() { slots[slotIndex] = group[i] }
            Self.commit(slots, display: uuid, into: &p)
        }
    }

    /// Removes the full-screen Space at `position`. Its owner windows follow `removal`.
    public mutating func removeFullScreenSpace(onDisplay uuid: String, position: Int,
                                               removal: FullScreenRemoval) throws {
        try edit { p in
            let display = try Self.requireDisplay(uuid, in: p)
            var slots = Self.slots(of: p, display: uuid)
            guard let at = slots.firstIndex(where: { $0.space.position == position }) else {
                throw ProfileDraftError.unknownSpace(display: uuid, position: position)
            }
            guard slots[at].space.kind == .fullScreen else { throw ProfileDraftError.notFullScreenSpace(position: position) }
            let owners = Set(slots[at].space.fullScreenWindowIDs)
            switch removal {
            case .moveWindows(let desktop):
                _ = try Self.desktopSlotIndex(desktop, in: slots, display: uuid)
                for i in p.windows.indices where owners.contains(p.windows[i].id) {
                    p.windows[i].isFullScreen = false
                    p.windows[i].placement = .desktop(number: desktop)
                    p.windows[i].frame = Self.frame(forRelative: p.windows[i].relativeFrame, in: display)
                }
            case .deleteWindows:
                p.windows.removeAll { owners.contains($0.id) }
            }
            slots.remove(at: at)
            Self.commit(slots, display: uuid, into: &p)
        }
    }

    // MARK: Windows

    /// Adds a planned window for `app` on Desktop `desktop` of a monitor. Give `relativeFrame` (fractions of
    /// the visible frame) or `frame` (global); with neither the window is 50% x 70% and centered. Returns the
    /// new window's id.
    @discardableResult
    public mutating func addPlannedWindow(app: AppRef, onDisplay uuid: String, desktop: Int,
                                          frame: CGRect? = nil, relativeFrame: CGRect? = nil,
                                          zoneName: String? = nil, id: UUID = UUID()) throws -> UUID {
        try edit { p in
            let display = try Self.requireDisplay(uuid, in: p)
            guard p.spaces.contains(where: { $0.displayUUID == uuid && $0.kind == .desktop && $0.desktopNumber == desktop }) else {
                throw ProfileDraftError.unknownDesktop(display: uuid, number: desktop)
            }
            let rel = relativeFrame ?? frame.map { Self.relative(forFrame: $0, in: display) } ?? Self.defaultRelativeFrame
            let abs = frame ?? Self.frame(forRelative: rel, in: display)
            let index = p.windows(for: app).count
            for i in p.windows.indices { p.windows[i].zIndex += 1 }
            p.windows.append(WindowSnapshot(id: id, app: app, indexInApp: index, displayUUID: uuid, frame: abs,
                                            relativeFrame: rel, placement: .desktop(number: desktop), zIndex: 0,
                                            origin: .planned, zoneName: zoneName))
            return id
        }
    }

    /// Sets a window's position and size from a global frame (or fractions with `setRelativeFrame`).
    public mutating func setFrame(ofWindow id: UUID, frame: CGRect, zoneName: String? = nil) throws {
        try edit { p in
            let i = try Self.windowIndex(id, in: p)
            let display = try Self.requireDisplay(p.windows[i].displayUUID, in: p)
            let frame = Self.clamped(frame, for: p.windows[i])
            p.windows[i].frame = frame
            p.windows[i].relativeFrame = Self.relative(forFrame: frame, in: display)
            p.windows[i].zoneName = zoneName
        }
    }

    /// `proposed` held to what the window accepts (fixed width / height, min / max); unchanged without known limits.
    public static func clamped(_ proposed: CGRect, for window: WindowSnapshot) -> CGRect {
        guard let limits = window.resizeLimits, limits.hasRestrictions else { return proposed }
        return limits.clamp(proposed, current: window.frame)
    }

    public mutating func setRelativeFrame(ofWindow id: UUID, relativeFrame: CGRect, zoneName: String? = nil) throws {
        try edit { p in
            let i = try Self.windowIndex(id, in: p)
            let display = try Self.requireDisplay(p.windows[i].displayUUID, in: p)
            let frame = Self.clamped(Self.frame(forRelative: relativeFrame, in: display), for: p.windows[i])
            p.windows[i].frame = frame
            p.windows[i].relativeFrame = frame == Self.frame(forRelative: relativeFrame, in: display)
                ? relativeFrame : Self.relative(forFrame: frame, in: display)
            p.windows[i].zoneName = zoneName
        }
    }

    /// Moves a normal window to Desktop `desktop` of monitor `uuid`; its relative frame is kept.
    public mutating func moveWindow(_ id: UUID, toDisplay uuid: String, desktop: Int) throws {
        try edit { p in
            let i = try Self.windowIndex(id, in: p)
            let display = try Self.requireDisplay(uuid, in: p)
            guard p.spaces.contains(where: { $0.displayUUID == uuid && $0.kind == .desktop && $0.desktopNumber == desktop }) else {
                throw ProfileDraftError.unknownDesktop(display: uuid, number: desktop)
            }
            if p.spaces.contains(where: { $0.fullScreenWindowIDs.contains(id) }) {
                throw ProfileDraftError.windowAlreadyFullScreen(id)
            }
            p.windows[i].displayUUID = uuid
            p.windows[i].placement = .desktop(number: desktop)
            p.windows[i].frame = Self.frame(forRelative: p.windows[i].relativeFrame, in: display)
        }
    }

    /// Removes a window. A full-screen Space it owned alone is removed too (a Split View Space keeps the other
    /// window); positions and Desktop numbers are renumbered.
    public mutating func removeWindow(_ id: UUID) throws {
        try edit { p in
            _ = try Self.windowIndex(id, in: p)
            let display = p.windows.first(where: { $0.id == id })!.displayUUID
            var slots = Self.slots(of: p, display: display)
            slots.removeAll { $0.space.kind == .fullScreen && $0.space.fullScreenWindowIDs == [id] }
            for i in slots.indices { slots[i].space.fullScreenWindowIDs.removeAll { $0 == id } }
            p.windows.removeAll { $0.id == id }
            Self.commit(slots, display: display, into: &p)
        }
    }

    public mutating func setRestore(_ restore: Bool, forWindow id: UUID) throws {
        try edit { p in p.windows[try Self.windowIndex(id, in: p)].restore = restore }
    }

    public mutating func setMinimized(_ minimized: Bool, forWindow id: UUID) throws {
        try edit { p in p.windows[try Self.windowIndex(id, in: p)].isMinimized = minimized }
    }

    private static func windowIndex(_ id: UUID, in p: Profile) throws -> Int {
        guard let i = p.windows.firstIndex(where: { $0.id == id }) else { throw ProfileDraftError.unknownWindow(id) }
        return i
    }

    // MARK: Per-profile settings

    public mutating func setOptions(_ change: (inout ProfileOptions) -> Void) throws {
        try edit { p in change(&p.options) }
    }

    public mutating func setLaunchPlan(_ plan: LaunchPlan?) throws {
        try edit { p in p.launchPlan = plan }
    }

    public mutating func setName(_ name: String) throws {
        try edit { p in p.name = name }
    }
}
