import Foundation

// Probes for "Virtual desktops" mode, part 3: reading raw trackpad touches so the app can recognize its own
// 3-finger swipe for switching workspaces.
//
// The private MultitouchSupport.framework is loaded with dlopen. Function names and the MTTouch struct
// layout come from two open-source projects (the code here is our own):
//   - OpenMultitouchSupport by Kyome22, MIT, https://github.com/Kyome22/OpenMultitouchSupport
//   - go-macos/multitouch, BSD-3-Clause, https://github.com/go-macos/multitouch
// This only reads touches. macOS still sees the same touches and still performs its own 3-finger swipe
// (switch Desktop / Mission Control) at the same time; this reader cannot cancel it.

// MARK: - Touch data

/// One finger in one frame, decoded from MTTouch.
public struct TouchPoint: Codable, Equatable {
    /// MTTouchState: 1 start in range, 2 hover, 3 make touch, 4 touching, 5 break touch, 6 linger, 7 out of range.
    public var state: Int32
    public var fingerID: Int32
    /// Normalized position on the trackpad: x 0 (left) ... 1 (right), y 0 (bottom, near the user) ... 1 (top).
    public var x: Double
    public var y: Double
    public var velocityX: Double
    public var velocityY: Double

    public init(state: Int32, fingerID: Int32, x: Double, y: Double, velocityX: Double = 0, velocityY: Double = 0) {
        self.state = state
        self.fingerID = fingerID
        self.x = x
        self.y = y
        self.velocityX = velocityX
        self.velocityY = velocityY
    }

    /// A finger that is on the glass: "make touch" or "touching".
    public var isDown: Bool { state == 3 || state == 4 }
}

/// All fingers the trackpad reported at one moment.
public struct TouchFrame: Equatable {
    /// Seconds (device clock; only differences matter).
    public var timestamp: Double
    /// Index of the device in the list MTDeviceCreateList returned (a Mac can have several: built-in
    /// trackpad, Magic Trackpad, Magic Mouse).
    public var device: Int
    public var touches: [TouchPoint]

    public init(timestamp: Double, device: Int = 0, touches: [TouchPoint]) {
        self.timestamp = timestamp
        self.device = device
        self.touches = touches
    }

    public var downCount: Int { touches.filter(\.isDown).count }
}

// MARK: - Swipe recognizer (pure)

public enum SwipeDirection: String, Codable {
    /// The fingers moved to the left on the trackpad (raw movement, not the scroll-direction setting).
    case left
    case right
}

public struct SwipeEvent: Codable, Equatable {
    public var direction: SwipeDirection
    /// Horizontal travel of the fingers' center, in trackpad widths (1.0 = the full width).
    public var travel: Double
    /// Vertical travel (signed; up is positive), in the same unit.
    public var drift: Double
    public var duration: Double

    public init(direction: SwipeDirection, travel: Double, drift: Double, duration: Double) {
        self.direction = direction
        self.travel = travel
        self.drift = drift
        self.duration = duration
    }
}

/// Recognizes a horizontal swipe with an exact number of fingers. Feed it frames of ONE device in time
/// order; it returns an event once, as soon as the fingers have traveled far enough, and then stays quiet
/// until all fingers are lifted. Pure: no system calls, so it can be tested with made-up frames.
public struct SwipeRecognizer {
    public struct Configuration: Equatable {
        /// Exact number of fingers on the glass.
        public var fingers: Int
        /// Horizontal travel of the center needed, in trackpad widths.
        public var minTravel: Double
        /// Allowed vertical travel as a share of the horizontal travel.
        public var maxVerticalRatio: Double
        /// The travel must be reached within this many seconds of the fingers landing.
        public var maxDuration: Double

        public init(fingers: Int = 3, minTravel: Double = 0.12, maxVerticalRatio: Double = 0.6,
                    maxDuration: Double = 1.2) {
            self.fingers = fingers
            self.minTravel = minTravel
            self.maxVerticalRatio = maxVerticalRatio
            self.maxDuration = maxDuration
        }
    }

    private enum Phase: Equatable {
        /// Waiting for the right number of fingers.
        case idle
        /// The right number of fingers landed; the center and time at that moment.
        case tracking(x: Double, y: Double, time: Double)
        /// Finished or cancelled; waits until every finger is up.
        case locked
    }

    public var configuration: Configuration
    private var phase: Phase = .idle

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public mutating func reset() { phase = .idle }

    @discardableResult
    public mutating func feed(_ frame: TouchFrame) -> SwipeEvent? {
        feed(timestamp: frame.timestamp, touches: frame.touches)
    }

    /// Returns a `SwipeEvent` on the frame where the swipe is first recognized, otherwise nil.
    @discardableResult
    public mutating func feed(timestamp: Double, touches: [TouchPoint]) -> SwipeEvent? {
        let down = touches.filter(\.isDown)
        let count = down.count

        switch phase {
        case .idle:
            if count == configuration.fingers {
                let c = SwipeRecognizer.center(of: down)
                phase = .tracking(x: c.x, y: c.y, time: timestamp)
            }
            return nil

        case .locked:
            if count == 0 { phase = .idle }
            return nil

        case .tracking(let startX, let startY, let startTime):
            // A finger was added or lifted: not a clean N-finger swipe.
            guard count == configuration.fingers else {
                phase = count == 0 ? .idle : .locked
                return nil
            }
            let duration = timestamp - startTime
            guard duration <= configuration.maxDuration else {
                phase = .locked
                return nil
            }
            let c = SwipeRecognizer.center(of: down)
            let dx = c.x - startX
            let dy = c.y - startY
            if abs(dx) >= configuration.minTravel, abs(dy) <= abs(dx) * configuration.maxVerticalRatio {
                phase = .locked
                return SwipeEvent(direction: dx < 0 ? .left : .right, travel: dx, drift: dy, duration: duration)
            }
            // Clearly a vertical gesture (Mission Control, App Expose): give up on this touch.
            if abs(dy) >= configuration.minTravel, abs(dy) > abs(dx) {
                phase = .locked
            }
            return nil
        }
    }

    private static func center(of points: [TouchPoint]) -> (x: Double, y: Double) {
        guard !points.isEmpty else { return (0, 0) }
        let n = Double(points.count)
        return (points.reduce(0) { $0 + $1.x } / n, points.reduce(0) { $0 + $1.y } / n)
    }
}

// MARK: - Device reader

public enum TrackpadReaderError: Error, LocalizedError, Equatable {
    case frameworkNotLoaded(String?)
    case symbolMissing(String)
    case noDevices

    public var errorDescription: String? {
        switch self {
        case .frameworkNotLoaded(let detail):
            return "MultitouchSupport could not be loaded" + (detail.map { ": \($0)" } ?? "")
        case .symbolMissing(let name):
            return "MultitouchSupport does not export \(name) on this macOS version"
        case .noDevices:
            return "MultitouchSupport reports no multitouch devices"
        }
    }
}

/// What `TrackpadReader.probe()` found. Read-only: no device is started.
public struct TrackpadProbe: Codable, Equatable {
    public struct Device: Codable, Equatable {
        public var index: Int
        /// nil when the optional MTDeviceIsBuiltIn symbol is missing.
        public var isBuiltIn: Bool?
        public var deviceID: UInt64?
        public var familyID: Int32?
        /// Sensor size in 1/100 mm, when the framework can tell.
        public var sensorWidth: Int32?
        public var sensorHeight: Int32?
    }

    public var loaded: Bool
    public var loadError: String?
    public var symbols: [String: Bool]
    public var devices: [Device]
    /// Size of one MTTouch record the decoder assumes. 96 on current macOS.
    public var touchStride: Int
}

public final class TrackpadReader {
    public static let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    /// Layout of the MTTouch C struct (see the credits above), in bytes. The array the callback receives has
    /// `stride` bytes per finger.
    public enum Layout {
        public static let stride = 96
        public static let timestamp = 8        // Double
        public static let state = 20           // Int32
        public static let fingerID = 24        // Int32
        public static let positionX = 32       // Float, normalizedVector.position.x
        public static let positionY = 36       // Float
        public static let velocityX = 40       // Float, normalizedVector.velocity.x
        public static let velocityY = 44       // Float
    }

    // MARK: Loading

    private static let handle: UnsafeMutableRawPointer? = dlopen(frameworkPath, RTLD_LAZY)
    private static let openError: String? = {
        handle == nil ? dlerror().map { String(cString: $0) } : nil
    }()

    /// True when the framework could be loaded.
    public static var isLoaded: Bool { handle != nil }
    public static var loadError: String? { openError }

    public static let requiredSymbols = [
        "MTDeviceCreateList", "MTRegisterContactFrameCallback", "MTDeviceStart", "MTDeviceStop",
    ]
    public static let optionalSymbols = [
        "MTUnregisterContactFrameCallback", "MTDeviceIsBuiltIn", "MTDeviceGetDeviceID", "MTDeviceGetFamilyID",
        "MTDeviceGetSensorSurfaceDimensions",
    ]

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, MemoryLayout<T>.size == MemoryLayout<UnsafeRawPointer>.size,
              let found = dlsym(handle, name) else { return nil }
        return unsafeBitCast(found, to: T.self)
    }

    private static func requiredSymbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard isLoaded else { throw TrackpadReaderError.frameworkNotLoaded(loadError) }
        guard let found = symbol(name, as: type) else { throw TrackpadReaderError.symbolMissing(name) }
        return found
    }

    // C signatures (from the projects named above)
    private typealias ContactCallback = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterCallback = @convention(c) (UnsafeRawPointer, ContactCallback) -> Void
    private typealias DeviceStart = @convention(c) (UnsafeRawPointer, Int32) -> Void
    private typealias DeviceStop = @convention(c) (UnsafeRawPointer) -> Void
    private typealias IsBuiltIn = @convention(c) (UnsafeRawPointer) -> Bool
    private typealias GetDeviceID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UInt64>) -> Void
    private typealias GetInt32 = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<Int32>) -> Void
    private typealias GetSize = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void

    /// Every multitouch device. The array is deliberately not released (its devices must stay valid).
    private static func deviceList() throws -> (list: CFArray, devices: [UnsafeRawPointer]) {
        let create = try requiredSymbol("MTDeviceCreateList", as: CreateList.self)
        guard let list = create()?.takeUnretainedValue() else { return ([] as CFArray, []) }
        var devices: [UnsafeRawPointer] = []
        for i in 0..<CFArrayGetCount(list) {
            if let device = CFArrayGetValueAtIndex(list, i) { devices.append(device) }
        }
        return (list, devices)
    }

    // MARK: Probe

    /// Loads the framework and lists devices without starting any. Safe to run any time.
    public static func probe() -> TrackpadProbe {
        var symbols: [String: Bool] = [:]
        for name in requiredSymbols + optionalSymbols {
            symbols[name] = isLoaded && symbol(name, as: UnsafeRawPointer.self) != nil
        }
        var probe = TrackpadProbe(loaded: isLoaded, loadError: loadError, symbols: symbols, devices: [],
                                  touchStride: Layout.stride)
        guard isLoaded, let found = try? deviceList() else { return probe }

        let builtIn = symbol("MTDeviceIsBuiltIn", as: IsBuiltIn.self)
        let deviceIDGetter = symbol("MTDeviceGetDeviceID", as: GetDeviceID.self)
        let familyGetter = symbol("MTDeviceGetFamilyID", as: GetInt32.self)
        let sizeGetter = symbol("MTDeviceGetSensorSurfaceDimensions", as: GetSize.self)
        for (i, device) in found.devices.enumerated() {
            var info = TrackpadProbe.Device(index: i)
            info.isBuiltIn = builtIn?(device)
            // Scratch space is larger than needed in case a getter writes a wider value than expected.
            let scratch = UnsafeMutablePointer<Int32>.allocate(capacity: 8)
            defer { scratch.deallocate() }
            scratch.initialize(repeating: 0, count: 8)
            if let deviceIDGetter {
                scratch.withMemoryRebound(to: UInt64.self, capacity: 4) { pointer in
                    deviceIDGetter(device, pointer)
                    info.deviceID = pointer.pointee
                }
            }
            scratch.initialize(repeating: 0, count: 8)
            if let familyGetter {
                familyGetter(device, scratch)
                info.familyID = scratch.pointee
            }
            scratch.initialize(repeating: 0, count: 8)
            if let sizeGetter {
                sizeGetter(device, scratch, scratch + 4)
                info.sensorWidth = scratch.pointee
                info.sensorHeight = (scratch + 4).pointee
            }
            probe.devices.append(info)
        }
        return probe
    }

    // MARK: Decoding (pure given a buffer)

    /// Decodes `count` MTTouch records starting at `base`.
    public static func decodeTouches(_ base: UnsafeRawPointer, count: Int) -> [TouchPoint] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let record = base + i * Layout.stride
            return TouchPoint(
                state: record.loadUnaligned(fromByteOffset: Layout.state, as: Int32.self),
                fingerID: record.loadUnaligned(fromByteOffset: Layout.fingerID, as: Int32.self),
                x: Double(record.loadUnaligned(fromByteOffset: Layout.positionX, as: Float.self)),
                y: Double(record.loadUnaligned(fromByteOffset: Layout.positionY, as: Float.self)),
                velocityX: Double(record.loadUnaligned(fromByteOffset: Layout.velocityX, as: Float.self)),
                velocityY: Double(record.loadUnaligned(fromByteOffset: Layout.velocityY, as: Float.self)))
        }
    }

    // MARK: Reading

    /// The framework's callback has no context argument, so the running reader lives in a static.
    private static let stateLock = NSLock()
    private static var active: TrackpadReader?

    private static let contactCallback: ContactCallback = { device, touches, count, timestamp, _ in
        TrackpadReader.deliver(device: device, touches: touches, count: Int(count), timestamp: timestamp)
    }

    private static func deliver(device: UnsafeRawPointer?, touches: UnsafeRawPointer?, count: Int, timestamp: Double) {
        stateLock.lock()
        let reader = active
        let index = device.flatMap { reader?.deviceIndexes[$0] } ?? 0
        stateLock.unlock()
        guard let reader, let handler = reader.onFrame else { return }
        let decoded = touches.map { decodeTouches($0, count: count) } ?? []
        handler(TouchFrame(timestamp: timestamp, device: index, touches: decoded))
    }

    /// Called for every frame, on a thread the framework owns (not the main thread). Set before `start()`.
    public var onFrame: ((TouchFrame) -> Void)?

    private var devices: [UnsafeRawPointer] = []
    private var deviceList: CFArray?
    private var deviceIndexes: [UnsafeRawPointer: Int] = [:]
    public private(set) var isRunning = false

    public init() {}

    deinit { stop() }

    /// Registers the callback on every multitouch device and starts them. Returns how many devices run.
    /// Only one reader can run at a time.
    @discardableResult
    public func start() throws -> Int {
        guard !isRunning else { return devices.count }
        let register = try TrackpadReader.requiredSymbol("MTRegisterContactFrameCallback", as: RegisterCallback.self)
        let startDevice = try TrackpadReader.requiredSymbol("MTDeviceStart", as: DeviceStart.self)
        _ = try TrackpadReader.requiredSymbol("MTDeviceStop", as: DeviceStop.self)
        let found = try TrackpadReader.deviceList()
        guard !found.devices.isEmpty else { throw TrackpadReaderError.noDevices }

        TrackpadReader.stateLock.lock()
        devices = found.devices
        deviceList = found.list
        deviceIndexes = Dictionary(uniqueKeysWithValues: found.devices.enumerated().map { ($0.element, $0.offset) })
        TrackpadReader.active = self
        TrackpadReader.stateLock.unlock()

        for device in devices {
            register(device, TrackpadReader.contactCallback)
            startDevice(device, 0)
        }
        isRunning = true
        return devices.count
    }

    /// Unregisters the callback and stops the devices. Safe to call more than once.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        let unregister = TrackpadReader.symbol("MTUnregisterContactFrameCallback", as: RegisterCallback.self)
        let stopDevice = TrackpadReader.symbol("MTDeviceStop", as: DeviceStop.self)
        for device in devices {
            unregister?(device, TrackpadReader.contactCallback)
            stopDevice?(device)
        }
        TrackpadReader.stateLock.lock()
        if TrackpadReader.active === self { TrackpadReader.active = nil }
        TrackpadReader.stateLock.unlock()
        // The device list and its devices are kept: stopping a released device is a known crash source.
    }
}
