import CoreGraphics
import Foundation

// Size cycling for the window shortcuts. Pressing a direction's shortcut repeatedly moves the focused
// window through left half -> left two-thirds -> left one-third (and the same for the other directions).
// Pure geometry: the app layer reads the window and display frames, calls `nextFrame`, and sets the result.
// Frames are in one shared coordinate space (global top-left), the same space as the visible frame passed in.

public enum WindowSizeDirection: String, CaseIterable, Sendable {
    case left, right, top, bottom, center
}

public enum WindowSizeCycle {
    /// The three steps of every direction, as a fraction of the visible frame's width (horizontal) or height (vertical).
    public static let steps: [CGFloat] = [1.0 / 2.0, 2.0 / 3.0, 1.0 / 3.0]

    /// Largest difference (points, per edge) at which a window still counts as being at a step.
    public static let defaultTolerance: CGFloat = 8

    /// The frame for `step` (0...2) of `direction` inside `visible`.
    public static func frame(for direction: WindowSizeDirection, step: Int, visible: CGRect) -> CGRect {
        let fraction = steps[((step % steps.count) + steps.count) % steps.count]
        switch direction {
        case .left:
            return CGRect(x: visible.minX, y: visible.minY, width: visible.width * fraction, height: visible.height)
        case .right:
            let width = visible.width * fraction
            return CGRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
        case .top:
            return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height * fraction)
        case .bottom:
            let height = visible.height * fraction
            return CGRect(x: visible.minX, y: visible.maxY - height, width: visible.width, height: height)
        case .center:
            let width = visible.width * fraction
            let height = visible.height * fraction
            return CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
        }
    }

    /// The step (0...2) the window is currently at for `direction`, or nil when it matches none of them.
    public static func currentStep(of current: CGRect, direction: WindowSizeDirection, visible: CGRect,
                                   tolerance: CGFloat = defaultTolerance) -> Int? {
        steps.indices.first { step in
            approximatelyEqual(current, frame(for: direction, step: step, visible: visible), tolerance: tolerance)
        }
    }

    /// The frame to move to on the next press. A window that matches no step starts at step 0 (the half).
    public static func nextFrame(current: CGRect, visible: CGRect, direction: WindowSizeDirection,
                                 tolerance: CGFloat = defaultTolerance) -> CGRect {
        let next: Int
        if let step = currentStep(of: current, direction: direction, visible: visible, tolerance: tolerance) {
            next = (step + 1) % steps.count
        } else {
            next = 0
        }
        return frame(for: direction, step: next, visible: visible)
    }

    /// True when every edge of `a` is within `tolerance` of the matching edge of `b`.
    public static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = defaultTolerance) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
