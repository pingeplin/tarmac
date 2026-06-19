import Foundation

public enum DaemonClientError: Error, CustomStringConvertible, Sendable {
    case socketPathTooLong(String)
    case connectFailed(path: String, detail: String)

    public var description: String {
        switch self {
        case .socketPathTooLong(let p):
            return "socket path too long for sockaddr_un (max 104 bytes): \(p)"
        case .connectFailed(let path, let detail):
            return "could not connect to tarmacd at \(path): \(detail)"
        }
    }
}

/// Long-lived app connection to tarmacd: connects, sends `hello` (role "app"),
/// then a background read loop decodes frames and delivers `Message`s on
/// `deliveryQueue` (main by default).
public final class DaemonClient: @unchecked Sendable {
    public let socketPath: String

    public var onMessage: (@Sendable (Message) -> Void)?
    public var onDisconnect: (@Sendable (String) -> Void)?

    private let deliveryQueue: DispatchQueue
    private let readQueue = DispatchQueue(label: "tarmac.daemon.read")
    private let writeQueue = DispatchQueue(label: "tarmac.daemon.write")
    private let stateLock = NSLock()
    private var fd: Int32 = -1
    private var closed = false
    private var spawnedDaemon: Process?

    public init(socketPath: String? = nil, deliveryQueue: DispatchQueue = .main) {
        self.socketPath = socketPath ?? Self.resolveSocketPath()
        self.deliveryQueue = deliveryQueue
    }

    /// The app's build channel — the ONE audited `#if DEBUG` → `Channel`
    /// mapping (spec 2606.0003). Used by both socket resolution and the
    /// connect-failure diagnostic, so the mapping lives in exactly one place
    /// (never sprinkled through the path code).
    static var channel: ChannelPaths.Channel {
        #if DEBUG
        return .dev
        #else
        return .release
        #endif
    }

    /// `TARMAC_SOCKET` override (non-empty wins verbatim), else the per-channel
    /// default. The build configuration is the channel: a DEBUG build resolves
    /// under `dev/`, a release build keeps the flat legacy path byte-for-byte
    /// (spec 2606.0003). Pure derivation lives in `ChannelPaths`.
    public static func resolveSocketPath() -> String {
        ChannelPaths.socketPath(
            override: ProcessInfo.processInfo.environment["TARMAC_SOCKET"],
            home: NSHomeDirectory(),
            channel: channel
        )
    }

    /// The macOS `sockaddr_un.sun_path` capacity in bytes (incl. the NUL
    /// terminator). `connect` accepts a path iff its byte length is strictly
    /// less than this — leaving room for the NUL.
    public static let sunPathCapacity = 104

    /// PURE: does `path` fit a `sockaddr_un`? (byte length `< sunPathCapacity`).
    /// This is the exact predicate `connectOnce` enforces before binding the
    /// address (it throws `socketPathTooLong` when false), extracted so the
    /// `sockaddr_un` byte budget (spec S8/S8b) is unit-testable without a live
    /// socket.
    public static func fitsUnixSocketPath(_ path: String) -> Bool {
        path.utf8.count < sunPathCapacity
    }

    /// Blocking. Connects (auto-spawning `$TARMAC_DAEMON` with ~3 s of retries if
    /// the first attempt fails), sends hello, and starts the read loop.
    public func connect() throws {
        func detail(of error: Error) -> String {
            if case DaemonClientError.connectFailed(_, let d) = error { return d }
            return "\(error)"
        }
        do {
            try connectOnce()
        } catch {
            let bundleURL = Bundle.main.bundleURL
            let bundledDaemon = bundleURL.appendingPathComponent("Contents/MacOS/tarmacd").path
            let daemon = DaemonLaunch.resolveDaemonPath(
                env: ProcessInfo.processInfo.environment,
                bundleURL: bundleURL,
                bundledBinaryExists: FileManager.default.fileExists(atPath: bundledDaemon)
            )
            guard let daemonBin = daemon else {
                throw DaemonClientError.connectFailed(
                    path: socketPath,
                    detail: "\(detail(of: error)) — is tarmacd (\(ChannelPaths.channelLabel(Self.channel)) channel) running? (set TARMAC_SOCKET to point elsewhere, or TARMAC_DAEMON to auto-spawn it)"
                )
            }
            try spawnDaemon(at: daemonBin)
            let deadline = Date().addingTimeInterval(3.0)
            var lastError = error
            var connected = false
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                do {
                    try connectOnce()
                    connected = true
                    break
                } catch {
                    lastError = error
                }
            }
            guard connected else {
                throw DaemonClientError.connectFailed(
                    path: socketPath,
                    detail: "spawned \(daemonBin) (\(ChannelPaths.channelLabel(Self.channel)) channel) but the socket did not accept a connection within 3 s (last error: \(detail(of: lastError)))"
                )
            }
        }
        try sendBlocking(.hello(role: "app", v: 1))
        startReadLoop()
    }

    public func close() {
        stateLock.lock()
        closed = true
        let oldFD = fd
        fd = -1
        stateLock.unlock()
        if oldFD >= 0 {
            shutdown(oldFD, SHUT_RDWR)
            Darwin.close(oldFD)
        }
    }

    // MARK: - Send

    public func send(_ message: Message) {
        guard let framed = try? Framing.frame(message.encodedPayload()) else { return }
        writeQueue.async { [self] in
            if !writeAll(framed) {
                disconnect(reason: "write failed: \(String(cString: strerror(errno)))")
            }
        }
    }

    public func spawnTerm(termID: String, cols: Int, rows: Int, cwd: String?, cmd: [String]?) {
        send(.spawnTerm(termID: termID, cols: cols, rows: rows, cwd: cwd, cmd: cmd))
    }

    public func input(termID: String, bytes: Data) {
        send(.input(termID: termID, bytes: bytes))
    }

    public func resize(termID: String, cols: Int, rows: Int) {
        send(.resize(termID: termID, cols: cols, rows: rows))
    }

    public func open(path: String, termID: String? = nil) {
        send(.open(path: path, termID: termID))
    }

    public func docRead(path: String) {
        send(.docRead(path: path))
    }

    public func layout(dock: [String], tiles: [LayoutTile], board: BoardViewport? = nil, boardID: String? = nil) {
        send(.layout(dock: dock, tiles: tiles, board: board, boardID: boardID))
    }

    /// M3: make `boardID` the active board (the daemon replies with board_list +
    /// that board's restore).
    public func boardSwitch(boardID: String) {
        send(.boardSwitch(boardID: boardID))
    }

    /// M3: mint a fresh board (the daemon assigns the slug id and makes it active).
    public func boardCreate() {
        send(.boardCreate)
    }

    /// P5.4: rename `boardID` (an empty `name` clears it back to the slug). The
    /// daemon re-pushes board_list with the new name.
    public func boardRename(boardID: String, name: String) {
        send(.boardRename(boardID: boardID, name: name))
    }

    /// P5.4: delete `boardID`. The daemon refuses the last board and, when the
    /// deleted board was active, fixes the active board and re-pushes board_list +
    /// the new active board's restore.
    public func boardDelete(boardID: String) {
        send(.boardDelete(boardID: boardID))
    }

    // MARK: - Internals

    private func connectOnce() throws {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw DaemonClientError.connectFailed(path: socketPath, detail: "socket(): \(String(cString: strerror(errno)))")
        }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        guard Self.fitsUnixSocketPath(socketPath) else {
            Darwin.close(sock)
            throw DaemonClientError.socketPathTooLong(socketPath)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                // Safe: fitsUnixSocketPath guaranteed strlen(src) < dst.count.
                memcpy(dst.baseAddress!, src, strlen(src) + 1)
            }
        }

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(sock)
            throw DaemonClientError.connectFailed(path: socketPath, detail: detail)
        }

        stateLock.lock()
        fd = sock
        closed = false
        stateLock.unlock()
    }

    private func spawnDaemon(at binPath: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binPath)
        proc.standardInput = FileHandle.nullDevice
        // Hand the daemon (and the PTYs it spawns) a PATH that resolves the
        // bundled `tarmac` CLI, so `tarmac open` works inside the app's own
        // terminals even under a Finder launch (minimal launchd PATH). No-op for
        // `make run`, which already injects the debug build dir.
        let cliDir = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS").path
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = DaemonLaunch.injectCLIPath(base: environment["PATH"], cliDir: cliDir)
        proc.environment = environment
        do {
            try proc.run()
        } catch {
            throw DaemonClientError.connectFailed(
                path: socketPath,
                detail: "failed to launch TARMAC_DAEMON (\(binPath)): \(error)"
            )
        }
        stateLock.lock()
        spawnedDaemon = proc
        stateLock.unlock()
    }

    private func sendBlocking(_ message: Message) throws {
        let framed = try Framing.frame(message.encodedPayload())
        guard writeAll(framed) else {
            throw DaemonClientError.connectFailed(
                path: socketPath,
                detail: "handshake write failed: \(String(cString: strerror(errno)))"
            )
        }
    }

    private func startReadLoop() {
        let sock = currentFD()
        readQueue.async { [self] in
            var reason = "connection closed by daemon"
            while true {
                guard let header = readExact(4, from: sock) else { break }
                let n = (UInt32(header[0]) << 24) | (UInt32(header[1]) << 16) | (UInt32(header[2]) << 8) | UInt32(header[3])
                guard Int(n) <= Framing.maxFrameLength else {
                    reason = "protocol error: \(n)-byte frame exceeds the 16 MiB cap"
                    break
                }
                guard let payload = readExact(Int(n), from: sock) else { break }
                do {
                    let message = try Message.decode(payload: Data(payload))
                    deliveryQueue.async { [self] in onMessage?(message) }
                } catch {
                    // Malformed frame: log and continue (only over-cap frames are fatal).
                    FileHandle.standardError.write(Data("tarmac: dropping undecodable frame: \(error)\n".utf8))
                }
            }
            disconnect(reason: reason)
        }
    }

    private func readExact(_ n: Int, from sock: Int32) -> [UInt8]? {
        if n == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { p in
                read(sock, p.baseAddress!.advanced(by: got), n - got)
            }
            if r == 0 { return nil }
            if r < 0 {
                if errno == EINTR { continue }
                return nil
            }
            got += r
        }
        return buf
    }

    private func writeAll(_ data: Data) -> Bool {
        let sock = currentFD()
        guard sock >= 0 else { return false }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let r = write(sock, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if r < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if r == 0 { return false }
                offset += r
            }
            return true
        }
    }

    private func currentFD() -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return fd
    }

    private func disconnect(reason: String) {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        let oldFD = fd
        fd = -1
        stateLock.unlock()
        if oldFD >= 0 {
            shutdown(oldFD, SHUT_RDWR)
            Darwin.close(oldFD)
        }
        deliveryQueue.async { [self] in onDisconnect?(reason) }
    }
}
