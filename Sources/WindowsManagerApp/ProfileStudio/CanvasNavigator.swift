import AppKit
import SwiftUI

/// Figma-style navigation for the map: Space+drag, middle-mouse drag and two-finger scroll pan; pinch and
/// Cmd/Ctrl+scroll zoom around the pointer. Sits behind the canvas as a background and listens through an
/// `NSEvent` local monitor, so it never takes clicks from the tiles. Only events over this view count, and
/// Space is left alone whenever a text field is being edited.
struct CanvasNavigator: NSViewRepresentable {
    let model: ProfileMapModel

    func makeNSView(context: Context) -> NavigatorView {
        let view = NavigatorView()
        view.model = model
        return view
    }

    func updateNSView(_ view: NavigatorView, context: Context) { view.model = model }

    static func dismantleNSView(_ view: NavigatorView, coordinator: ()) { view.stop() }

    final class NavigatorView: NSView {
        var model: ProfileMapModel?
        private var monitor: Any?
        private var spaceHeld = false
        private var dragging = false
        private var cursorPushed = false

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            let mask: NSEvent.EventTypeMask = [.scrollWheel, .magnify, .keyDown, .keyUp, .leftMouseDown, .leftMouseDragged,
                                               .leftMouseUp, .otherMouseDown, .otherMouseDragged, .otherMouseUp, .mouseMoved]
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                guard let self else { return event }
                return MainActor.assumeIsolated { self.handle(event) }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            endNavigation()
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        // MARK: Events

        /// Returns nil when the event was used (it never reaches the tiles), else the event.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let model, event.window === window else { return event }
            // Key events carry no pointer position: use where the pointer is now.
            let location = (event.type == .keyDown || event.type == .keyUp)
                ? (window?.mouseLocationOutsideOfEventStream ?? .zero) : event.locationInWindow
            let point = convert(location, from: nil)
            let inside = bounds.contains(point)
            switch event.type {
            case .keyDown:
                guard event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      inside || spaceHeld, window?.isKeyWindow == true, !isEditingText else { return event }
                if !spaceHeld {
                    spaceHeld = true
                    model.panModeActive = true
                    updateCursor()
                }
                return nil
            case .keyUp:
                guard event.keyCode == 49, spaceHeld else { return event }
                spaceHeld = false
                if !dragging { endNavigation() }
                return nil
            case .scrollWheel:
                guard inside else { return event }
                let precise = event.hasPreciseScrollingDeltas
                if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                    let step = event.scrollingDeltaY * (precise ? 0.01 : 0.05)
                    model.zoomBy(exp(Double(step)), around: point)
                } else {
                    let scale: CGFloat = precise ? 1 : 10
                    model.panBy(CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale))
                }
                return nil
            case .magnify:
                guard inside else { return event }
                model.zoomBy(1 + Double(event.magnification), around: point)
                return nil
            case .leftMouseDown:
                guard spaceHeld, inside else { return event }
                dragging = true
                updateCursor()
                return nil
            case .otherMouseDown:
                guard event.buttonNumber == 2, inside else { return event }
                dragging = true
                updateCursor()
                return nil
            case .leftMouseDragged, .otherMouseDragged:
                guard dragging else { return event }
                model.panBy(CGSize(width: event.deltaX, height: event.deltaY))
                return nil
            case .leftMouseUp, .otherMouseUp:
                guard dragging else { return event }
                dragging = false
                if spaceHeld { updateCursor() } else { endNavigation() }
                return nil
            case .mouseMoved:
                if spaceHeld || dragging { updateCursor() }
                return event
            default:
                return event
            }
        }

        /// True while a text field (its field editor) has the keyboard, so Space types a space.
        private var isEditingText: Bool {
            guard let responder = window?.firstResponder else { return false }
            return responder is NSTextView || responder is NSTextField
        }

        // MARK: Cursor

        private func updateCursor() {
            let cursor: NSCursor = dragging ? .closedHand : .openHand
            if cursorPushed { NSCursor.pop() }
            cursor.push()
            cursor.set()
            cursorPushed = true
        }

        private func endNavigation() {
            spaceHeld = false
            dragging = false
            if cursorPushed { NSCursor.pop(); cursorPushed = false }
            if model?.panModeActive == true { model?.panModeActive = false }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endNavigation() }
        }
    }
}

/// A very low-contrast dot grid behind the map. It moves and scales with the pan and zoom so the canvas feels endless.
struct CanvasGridBackground: View {
    let zoom: Double
    let offset: CGPoint

    var body: some View {
        Canvas { context, size in
            // Dots every 24 canvas points; double the spacing while they would be closer than 10 screen points.
            var spacing = 24 * CGFloat(zoom)
            while spacing < 10 { spacing *= 2 }
            let startX = offset.x.truncatingRemainder(dividingBy: spacing)
            let startY = offset.y.truncatingRemainder(dividingBy: spacing)
            var path = Path()
            var y = startY < 0 ? startY + spacing : startY
            while y < size.height {
                var x = startX < 0 ? startX + spacing : startX
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                    x += spacing
                }
                y += spacing
            }
            context.fill(path, with: .color(.primary.opacity(0.1)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
