import Foundation

/// Thin glue: starts the raw `TrackpadReader`, feeds each device's frames to its own
/// `ThreeFingerSwipeRecognizer`, and calls `handler` with the mapped workspace command.
/// The handler runs on a thread owned by MultitouchSupport, not the main thread.
public final class SwipeMonitor {
    private let reader = TrackpadReader()
    private let lock = NSLock()
    private var recognizers: [Int: ThreeFingerSwipeRecognizer] = [:]
    private let configuration: ThreeFingerSwipeConfiguration
    private let mapping: SwipeWorkspaceMapping
    private let handler: (WorkspaceSwitchCommand) -> Void

    public init(configuration: ThreeFingerSwipeConfiguration = ThreeFingerSwipeConfiguration(),
                mapping: SwipeWorkspaceMapping = SwipeWorkspaceMapping(),
                handler: @escaping (WorkspaceSwitchCommand) -> Void) {
        self.configuration = configuration
        self.mapping = mapping
        self.handler = handler
    }

    public var isRunning: Bool { reader.isRunning }

    /// Starts reading. Returns how many devices run. Throws `TrackpadReaderError` when unavailable.
    @discardableResult
    public func start() throws -> Int {
        reader.onFrame = { [weak self] frame in self?.receive(frame) }
        return try reader.start()
    }

    public func stop() {
        reader.stop()
        reader.onFrame = nil
        lock.lock()
        recognizers.removeAll()
        lock.unlock()
    }

    private func receive(_ frame: TouchFrame) {
        lock.lock()
        var recognizer = recognizers[frame.device] ?? ThreeFingerSwipeRecognizer(configuration: configuration)
        let event = recognizer.feed(frame)
        recognizers[frame.device] = recognizer
        lock.unlock()
        if let event { handler(mapping.command(for: event.swipe)) }
    }
}
