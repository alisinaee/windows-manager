import Foundation
import Darwin

enum IPCSocket {
    static func makeAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    static func bindAndListen(_ path: String) throws -> Int32 {
        guard var addr = makeAddress(path) else { throw IPCError.io("socket path too long") }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // The socket is created with the process umask until the chmod below; keep everyone else out of its
        // directory (it may have existed with looser permissions, which createDirectory leaves alone).
        chmod(dir, 0o700)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.io("socket: \(String(cString: strerror(errno)))") }
        // No process-wide umask change here: it is global and races with file creation on other threads.
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { let m = String(cString: strerror(errno)); close(fd); throw IPCError.io("bind: \(m)") }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { let m = String(cString: strerror(errno)); close(fd); throw IPCError.io("listen: \(m)") }
        return fd
    }

    static func connect(_ path: String) throws -> Int32 {
        guard var addr = makeAddress(path) else { throw IPCError.io("socket path too long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.io("socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let e = errno; close(fd)
            if e == ENOENT || e == ECONNREFUSED { throw IPCError.notRunning }
            throw IPCError.io("connect: \(String(cString: strerror(e)))")
        }
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var off = 0
        return data.withUnsafeBytes { raw -> Bool in
            while off < data.count {
                let n = write(fd, raw.baseAddress! + off, data.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }

    /// Reads until a full line arrives. Returns nil on EOF/timeout/error (reason in `timedOut`).
    static func readLine(_ fd: Int32, buffer: inout IPCLineBuffer, deadline: Date) -> (line: Data?, timedOut: Bool) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let l = buffer.nextLine() { return (l, false) }
            if buffer.overflowed { return (nil, false) }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return (nil, true) }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&p, 1, Int32(min(remaining * 1000, 60_000)))
            if pr < 0 { if errno == EINTR { continue }; return (nil, false) }
            if pr == 0 { continue }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { if errno == EINTR { continue }; return (nil, false) }
            if n == 0 { return (buffer.nextLine(), false) }
            buffer.append(Data(chunk[0..<n]))
        }
    }
}

/// One-shot client: connect, send a request line, read one response line.
public struct IPCClient: Sendable {
    public var socketPath: String
    public var timeout: TimeInterval
    public init(socketPath: String = IPCPaths.defaultSocketPath, timeout: TimeInterval = 5) {
        self.socketPath = socketPath; self.timeout = timeout
    }

    public func send(_ request: IPCRequest) throws -> IPCResponse {
        let fd = try IPCSocket.connect(socketPath)
        defer { close(fd) }
        guard IPCSocket.writeAll(fd, try IPCCodec.encode(request)) else { throw IPCError.io("write failed") }
        var buf = IPCLineBuffer()
        let r = IPCSocket.readLine(fd, buffer: &buf, deadline: Date().addingTimeInterval(timeout))
        guard let line = r.line else { throw r.timedOut ? IPCError.timeout : IPCError.io("connection closed") }
        return try IPCCodec.decodeResponse(line)
    }

    public func send(_ command: String, args: [String: JSONValue] = [:]) throws -> IPCResponse {
        try send(IPCRequest(command: command, args: args))
    }
}

/// Listens on a Unix socket (0600) and answers one request per line on a background thread.
/// The handler runs on the connection thread; hop to the main actor inside it if needed.
public final class IPCServer: @unchecked Sendable {
    public let socketPath: String
    private let handler: @Sendable (IPCRequest) -> IPCResponse
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var running = false

    public init(socketPath: String = IPCPaths.defaultSocketPath, handler: @escaping @Sendable (IPCRequest) -> IPCResponse) {
        self.socketPath = socketPath; self.handler = handler
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        listenFD = try IPCSocket.bindAndListen(socketPath)
        running = true
        let fd = listenFD
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "wm.ipc.accept"
        t.start()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        running = false
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        unlink(socketPath)
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            let c = accept(fd, nil, nil)
            if c < 0 { if errno == EINTR { continue }; return }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let h = handler
            let t = Thread { IPCServer.serve(c, h) }
            t.name = "wm.ipc.conn"
            t.start()
        }
    }

    private static func serve(_ fd: Int32, _ handler: @Sendable (IPCRequest) -> IPCResponse) {
        defer { close(fd) }
        var buf = IPCLineBuffer()
        // Serve lines until the peer closes; each connection is short-lived.
        while true {
            let r = IPCSocket.readLine(fd, buffer: &buf, deadline: Date().addingTimeInterval(30))
            guard let line = r.line else { return }
            let response: IPCResponse
            do { response = handler(try IPCCodec.decodeRequest(line)) }
            catch { response = .failure(id: "", code: "bad_request", message: "\(error)") }
            guard let out = try? IPCCodec.encode(response), IPCSocket.writeAll(fd, out) else { return }
        }
    }
}
