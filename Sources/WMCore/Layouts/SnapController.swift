import CoreGraphics
import Foundation

// Snap-while-dragging logic (phase P4.3). Pure state machine: the app layer feeds it mouse and modifier
// events (already converted to global top-left coordinates) and does what the returned output says.
// Nothing here touches AppKit or Accessibility.

/// Modifier keys the snap gesture can use.
public struct SnapModifierFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = SnapModifierFlags(rawValue: 1 << 0)
    public static let control = SnapModifierFlags(rawValue: 1 << 1)
    public static let option = SnapModifierFlags(rawValue: 1 << 2)
    public static let command = SnapModifierFlags(rawValue: 1 << 3)
}

public enum SnapModifier: String, Codable, CaseIterable, Sendable, Identifiable {
    case option, control, command, shift

    public var id: String { rawValue }

    public var flag: SnapModifierFlags {
        switch self {
        case .option: return .option
        case .control: return .control
        case .command: return .command
        case .shift: return .shift
        }
    }

    public var title: String {
        switch self {
        case .option: return "Option"
        case .control: return "Control"
        case .command: return "Command"
        case .shift: return "Shift"
        }
    }
}

/// User settings for the snap overlay. Missing keys decode to the defaults.
public struct SnapSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var modifier: SnapModifier
    /// How far (points) the pointer must travel before a press counts as a drag.
    public var minimumDragDistance: Double
    /// How long (seconds) the pointer must stay in a zone before the highlight moves to it.
    public var debounce: Double
    /// Space between zones and at the display edge when a window is placed.
    public var gap: Double

    public init(enabled: Bool = true, modifier: SnapModifier = .option, minimumDragDistance: Double = 8,
                debounce: Double = 0.05, gap: Double = 0) {
        self.enabled = enabled
        self.modifier = modifier
        self.minimumDragDistance = minimumDragDistance
        self.debounce = debounce
        self.gap = gap
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SnapSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        modifier = try c.decodeIfPresent(SnapModifier.self, forKey: .modifier) ?? d.modifier
        minimumDragDistance = try c.decodeIfPresent(Double.self, forKey: .minimumDragDistance) ?? d.minimumDragDistance
        debounce = try c.decodeIfPresent(Double.self, forKey: .debounce) ?? d.debounce
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? d.gap
    }
}

/// The display under the pointer and the layout to snap into, in global top-left coordinates.
public struct SnapDisplay: Equatable, Sendable {
    public var id: String
    /// The area zones are laid over (usually the display's visible frame).
    public var frame: CGRect
    public var layout: Layout

    public init(id: String, frame: CGRect, layout: Layout) {
        self.id = id
        self.frame = frame
        self.layout = layout
    }
}

/// The window a press started on. `id` is opaque to the controller (the app maps it back to a real window).
public struct SnapWindow: Equatable, Sendable {
    public var id: UInt64
    public var frame: CGRect

    public init(id: UInt64, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

public struct SnapController: Sendable {
    public enum State: Equatable, Sendable {
        /// Nothing to do: no press, or a press that is not a window drag.
        case idle
        /// A window is being dragged, but no snap overlay (modifier not held, or no layout display).
        case dragging(windowID: UInt64)
        /// Overlay visible on `display`; `zoneID` is the highlighted zone, if any.
        case snapping(windowID: UInt64, display: SnapDisplay, zoneID: UUID?)
    }

    public enum Output: Equatable, Sendable {
        case none
        /// `state` changed; the app updates the overlay accordingly.
        case stateChanged(State)
        /// Mouse-up on a highlighted zone: put window `windowID` at `frame` (global top-left coordinates).
        case commit(windowID: UInt64, frame: CGRect)
        /// The gesture ended without a snap; hide the overlay.
        case cancel
    }

    public private(set) var state: State = .idle
    public var settings: SnapSettings

    // Press tracking.
    private var window: SnapWindow?
    private var start: CGPoint = .zero
    private var confirmed = false   // the pointer moved far enough AND the window moved with it
    private var ignored = false     // not a plain window move (resize, or the window did not follow)

    // Debounce: a zone must stay under the pointer for `settings.debounce` before it is highlighted.
    private var candidate: UUID?
    private var candidateSince: TimeInterval = 0

    public init(settings: SnapSettings = SnapSettings()) {
        self.settings = settings
    }

    /// True while a press is not yet known to be a window move; the app should pass `windowFrame` to `dragged`.
    public var needsWindowFrame: Bool { window != nil && !confirmed && !ignored }

    public var isActive: Bool { window != nil }

    // MARK: Events

    public mutating func mouseDown(at point: CGPoint, window: SnapWindow?) -> Output {
        let output = reset()
        guard settings.enabled, let window else { return output }
        self.window = window
        start = point
        return output
    }

    /// `windowFrame` is the dragged window's current frame (needed while `needsWindowFrame` is true).
    public mutating func dragged(to point: CGPoint, flags: SnapModifierFlags, display: SnapDisplay?,
                                 windowFrame: CGRect? = nil, at time: TimeInterval) -> Output {
        guard let window, !ignored else { return .none }
        if !confirmed {
            guard hypot(point.x - start.x, point.y - start.y) >= settings.minimumDragDistance else { return .none }
            guard let windowFrame else { return .none }
            // A move keeps the size and shifts the origin; anything else (resize, window stayed put) is not ours.
            let sameSize = abs(windowFrame.width - window.frame.width) < 1 && abs(windowFrame.height - window.frame.height) < 1
            let moved = hypot(windowFrame.minX - window.frame.minX, windowFrame.minY - window.frame.minY) >= 1
            if !sameSize { ignored = true; return .none }
            guard moved else { return .none }
            confirmed = true
        }
        return evaluate(point: point, flags: flags, display: display, time: time, immediate: false)
    }

    /// The modifier keys changed mid-drag.
    public mutating func flagsChanged(_ flags: SnapModifierFlags, at point: CGPoint, display: SnapDisplay?,
                                      time: TimeInterval) -> Output {
        guard window != nil, confirmed else { return .none }
        return evaluate(point: point, flags: flags, display: display, time: time, immediate: false)
    }

    /// Lets a stable candidate zone become the highlight when the pointer stopped moving.
    public mutating func tick(flags: SnapModifierFlags, at point: CGPoint, display: SnapDisplay?,
                              time: TimeInterval) -> Output {
        guard window != nil, confirmed else { return .none }
        return evaluate(point: point, flags: flags, display: display, time: time, immediate: false)
    }

    public mutating func mouseUp(at point: CGPoint, flags: SnapModifierFlags, display: SnapDisplay?) -> Output {
        defer { _ = reset() }
        guard let window, confirmed, !ignored, settings.enabled,
              flags.contains(settings.modifier.flag), let display,
              let zone = display.layout.zone(at: point, in: display.frame) else {
            return state == .idle ? .none : .cancel
        }
        let frame = LayoutGeometry.frame(of: zone, in: display.frame, gap: CGFloat(settings.gap))
        guard frame.width > 0, frame.height > 0 else { return .cancel }
        return .commit(windowID: window.id, frame: frame)
    }

    /// Abort the gesture (for example Escape or the monitor stopping).
    public mutating func cancel() -> Output { reset() }

    // MARK: Internals

    private mutating func reset() -> Output {
        let wasShowing = state != .idle
        window = nil
        confirmed = false
        ignored = false
        candidate = nil
        state = .idle
        return wasShowing ? .cancel : .none
    }

    private mutating func evaluate(point: CGPoint, flags: SnapModifierFlags, display: SnapDisplay?,
                                   time: TimeInterval, immediate: Bool) -> Output {
        guard let window else { return .none }
        let new: State
        if settings.enabled, flags.contains(settings.modifier.flag), let display {
            let hit = display.layout.zone(at: point, in: display.frame)?.id
            var highlighted: UUID?
            if case .snapping(_, let shown, let current) = state, shown.id == display.id {
                highlighted = current
            }
            if hit == highlighted {
                candidate = nil
            } else if hit == nil || immediate {
                // Leaving every zone clears at once; there is nothing to flicker between.
                highlighted = hit
                candidate = nil
            } else {
                if candidate != hit { candidate = hit; candidateSince = time }
                if time - candidateSince >= settings.debounce {
                    highlighted = hit
                    candidate = nil
                }
            }
            new = .snapping(windowID: window.id, display: display, zoneID: highlighted)
        } else {
            candidate = nil
            new = .dragging(windowID: window.id)
        }
        guard new != state else { return .none }
        state = new
        return .stateChanged(new)
    }
}
