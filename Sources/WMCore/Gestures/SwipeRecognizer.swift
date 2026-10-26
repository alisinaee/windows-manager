import Foundation

// Phase P5.4: recognizes a three-finger horizontal swipe from raw trackpad frames so virtual workspaces can
// switch. Pure logic (no system calls), fed with `TouchFrame`s from `TrackpadReader`.
//
// Note: TrackpadReader.swift has an older, simpler `SwipeRecognizer`; this one is stricter (finger identity,
// velocity, dominant-axis check, cooldown) and has its own names so both can coexist.

/// A recognized swipe, in raw trackpad terms (not the scroll-direction setting).
public enum ThreeFingerSwipe: String, Codable, Equatable, Sendable {
    /// Fingers moved toward the left edge of the trackpad.
    case swipeLeft
    /// Fingers moved toward the right edge of the trackpad.
    case swipeRight
}

/// Details of one recognized swipe.
public struct ThreeFingerSwipeEvent: Codable, Equatable, Sendable {
    public var swipe: ThreeFingerSwipe
    /// Mean horizontal travel of the three fingers, signed (right is positive), in trackpad widths.
    public var travel: Double
    /// Mean vertical travel, signed (up is positive), in trackpad heights.
    public var drift: Double
    /// Seconds from the third finger landing to recognition.
    public var duration: Double
    /// Mean horizontal speed over `duration`, in trackpad widths per second (absolute value).
    public var velocity: Double

    public init(swipe: ThreeFingerSwipe, travel: Double, drift: Double, duration: Double, velocity: Double) {
        self.swipe = swipe
        self.travel = travel
        self.drift = drift
        self.duration = duration
        self.velocity = velocity
    }
}

/// Thresholds for `ThreeFingerSwipeRecognizer`. All injectable.
public struct ThreeFingerSwipeConfiguration: Equatable, Sendable {
    /// Exact number of fingers on the glass.
    public var fingers: Int
    /// Mean horizontal travel needed, in normalized trackpad widths.
    public var minTravel: Double
    /// Horizontal travel must exceed this multiple of the vertical travel (|dx| > ratio * |dy|).
    public var horizontalDominance: Double
    /// The travel must be reached within this many seconds of the last finger landing.
    public var maxDuration: Double
    /// Minimum mean speed (trackpad widths per second); filters slow drifting.
    public var minVelocity: Double
    /// After a swipe fires, another one is ignored until this many seconds passed (even if fingers lifted).
    public var cooldown: Double

    public init(fingers: Int = 3, minTravel: Double = 0.25, horizontalDominance: Double = 2.0,
                maxDuration: Double = 0.8, minVelocity: Double = 0.15, cooldown: Double = 0.3) {
        self.fingers = fingers
        self.minTravel = minTravel
        self.horizontalDominance = horizontalDominance
        self.maxDuration = maxDuration
        self.minVelocity = minVelocity
        self.cooldown = cooldown
    }
}

/// Recognizes a horizontal swipe with exactly N fingers (default 3). Feed it frames of ONE device in time
/// order. It reports a swipe once per gesture, as soon as the mean travel passes the threshold, and then
/// stays quiet until every finger is lifted. A gesture is abandoned (until all fingers lift) when the finger
/// count changes, a finger is replaced, the motion is not mostly horizontal, or the time window runs out.
public struct ThreeFingerSwipeRecognizer {
    private struct Start {
        var time: Double
        /// Finger id -> position when the group of N fingers was complete.
        var positions: [Int32: (x: Double, y: Double)]
    }

    private enum Phase {
        case idle
        case tracking(Start)
        /// Fired or cancelled; waits until every finger is up.
        case locked
    }

    public var configuration: ThreeFingerSwipeConfiguration
    private var phase: Phase = .idle
    private var lastFired: Double?

    public init(configuration: ThreeFingerSwipeConfiguration = ThreeFingerSwipeConfiguration()) {
        self.configuration = configuration
    }

    /// Forgets the current gesture and the cooldown.
    public mutating func reset() {
        phase = .idle
        lastFired = nil
    }

    @discardableResult
    public mutating func feed(_ frame: TouchFrame) -> ThreeFingerSwipeEvent? {
        feed(timestamp: frame.timestamp, touches: frame.touches)
    }

    /// Returns an event on the frame where the swipe is first recognized, otherwise nil.
    @discardableResult
    public mutating func feed(timestamp: Double, touches: [TouchPoint]) -> ThreeFingerSwipeEvent? {
        let down = touches.filter(\.isDown)
        let count = down.count

        switch phase {
        case .idle:
            if count == configuration.fingers {
                let ids = Set(down.map(\.fingerID))
                if ids.count == count {
                    var positions: [Int32: (x: Double, y: Double)] = [:]
                    for t in down { positions[t.fingerID] = (t.x, t.y) }
                    phase = .tracking(Start(time: timestamp, positions: positions))
                } else {
                    phase = .locked
                }
            } else if count > configuration.fingers {
                // Too many fingers (e.g. 4): not our gesture, wait for lift.
                phase = .locked
            }
            return nil

        case .locked:
            if count == 0 { phase = .idle }
            return nil

        case .tracking(let start):
            guard count == configuration.fingers else {
                phase = count == 0 ? .idle : .locked
                return nil
            }
            // Same fingers only: a replaced finger invalidates the start positions.
            var dxSum = 0.0
            var dySum = 0.0
            for t in down {
                guard let origin = start.positions[t.fingerID] else {
                    phase = .locked
                    return nil
                }
                dxSum += t.x - origin.x
                dySum += t.y - origin.y
            }
            let n = Double(count)
            let dx = dxSum / n
            let dy = dySum / n
            let duration = timestamp - start.time

            guard duration <= configuration.maxDuration else {
                phase = .locked
                return nil
            }

            if abs(dx) > configuration.minTravel {
                let horizontal = abs(dx) > configuration.horizontalDominance * abs(dy)
                let velocity = duration > 0 ? abs(dx) / duration : .infinity
                let cooledDown = lastFired.map { timestamp - $0 >= configuration.cooldown } ?? true
                phase = .locked
                guard horizontal, velocity >= configuration.minVelocity, cooledDown else { return nil }
                lastFired = timestamp
                return ThreeFingerSwipeEvent(swipe: dx < 0 ? .swipeLeft : .swipeRight, travel: dx, drift: dy,
                                             duration: duration, velocity: velocity)
            }
            // Clearly vertical (Mission Control, App Expose): give up on this touch.
            if abs(dy) > configuration.minTravel {
                phase = .locked
            }
            return nil
        }
    }
}

/// Maps a swipe to a workspace command.
///
/// Default (natural scrolling, the macOS default): the content follows the fingers, so swiping the fingers
/// to the left pulls the next page in -> `.next`, and swiping right goes back -> `.previous`. This matches
/// how macOS itself switches Desktops with three/four fingers. With `naturalScroll = false` it is mirrored.
public struct SwipeWorkspaceMapping: Equatable, Sendable {
    public var naturalScroll: Bool

    public init(naturalScroll: Bool = true) {
        self.naturalScroll = naturalScroll
    }

    public func command(for swipe: ThreeFingerSwipe) -> WorkspaceSwitchCommand {
        switch (swipe, naturalScroll) {
        case (.swipeLeft, true), (.swipeRight, false): return .next
        case (.swipeRight, true), (.swipeLeft, false): return .previous
        }
    }
}
