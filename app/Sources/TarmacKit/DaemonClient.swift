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
    /// The build channel the socket was resolved for; named in the
    /// connect-failure diagnostics.
    public let channel: ChannelPaths.Channel
    /// Sent as `hello.app_version`. It must be the same string `tarmacd` reports
    /// as `daemon_version` for a matching install (the daemon's
    /// `CARGO_PKG_VERSION`), or `DaemonLaunch.shouldRestart` reads every daemon
    /// as stale. nil names no version.
    public let appVersion: String?

    public var onMessage: (@Sendable (Message) -> Void)?
    public var onDisconnect: (@Sendable (String) -> Void)?

    private let deliveryQueue: DispatchQueue
    private let readQueue = DispatchQueue(label: "tarmac.daemon.read")
    private let writeQueue = DispatchQueue(label: "tarmac.daemon.write")
    private let stateLock = NSLock()
    private var fd: Int32 = -1
    private var closed = false
    private var spawnedDaemon: Process?

    /// `channel` defaults to the build configuration (`ChannelPaths.Channel.build`,
    /// the one audited `#if DEBUG` mapping); pass it to override. An explicit
    /// `socketPath` wins over both it and `TARMAC_SOCKET`.
    public init(
        socketPath: String? = nil,
        channel: ChannelPaths.Channel = .build,
        appVersion: String? = nil,
        deliveryQueue: DispatchQueue = .main
    ) {
        self.socketPath = socketPath ?? Self.resolveSocketPath(channel: channel)
        self.channel = channel
        self.appVersion = appVersion
        self.deliveryQueue = deliveryQueue
    }

    /// `TARMAC_SOCKET` override (non-empty wins verbatim), else the per-channel
    /// default under `$HOME` (spec 2606.0003). The impure shell over
    /// `ChannelPaths`: the environment read happens here and nowhere else.
    public static func resolveSocketPath(channel: ChannelPaths.Channel = .build) -> String {
        let env = ProcessInfo.processInfo.environment
        return ChannelPaths.socketPath(
            override: env["TARMAC_SOCKET"],
            home: ChannelPaths.home(env: env),
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
                    detail: "\(detail(of: error)) — is tarmacd (\(ChannelPaths.channelLabel(channel)) channel) running? (set TARMAC_SOCKET to point elsewhere, or TARMAC_DAEMON to auto-spawn it)"
                )
            }
            let child = spawnedChild()
            if DaemonLaunch.maySpawn(alreadySpawned: child != nil, priorChildExited: !(child?.isRunning ?? false)) {
                try spawnDaemon(at: daemonBin)
            }
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
                    detail: "spawned \(daemonBin) (\(ChannelPaths.channelLabel(channel)) channel) but the socket did not accept a connection within 3 s (last error: \(detail(of: lastError)))"
                )
            }
        }
        try sendBlocking(.hello(role: "app", v: 1, appVersion: appVersion))
        startReadLoop()
    }

    /// The pid of the daemon this client spawned, if any — the fallback
    /// `DaemonLaunch.restartTarget` takes when `hello_ok` reports no pid.
    public var spawnedDaemonPid: Int? {
        spawnedChild().map { Int($0.processIdentifier) }
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

    public func spawnTerm(
        termID: String,
        cols: Int,
        rows: Int,
        cwd: String?,
        cmd: [String]?,
        boardID: String? = nil,
        inheritCwdFrom: String? = nil
    ) {
        send(.spawnTerm(
            termID: termID, cols: cols, rows: rows, cwd: cwd, cmd: cmd,
            boardID: boardID, inheritCwdFrom: inheritCwdFrom
        ))
    }

    public func input(termID: String, bytes: Data) {
        send(.input(termID: termID, bytes: bytes))
    }

    public func resize(termID: String, cols: Int, rows: Int) {
        send(.resize(termID: termID, cols: cols, rows: rows))
    }

    public func open(path: String, termID: String? = nil, boardID: String? = nil) {
        send(.open(path: path, termID: termID, boardID: boardID))
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

    /// issue #15: terminate one terminal's pty (the daemon SIGHUPs its process
    /// group). Used by ⌘W to close a single terminal card.
    public func termClose(termID: String) {
        send(.termClose(termID: termID))
    }

    /// issue #34: forget a doc (registry, dock, watcher). No reply frame.
    public func docClose(path: String) {
        send(.docClose(path: path))
    }

    /// issue #89: re-stat a doc now; the daemon answers with the usual
    /// `file_event`, changed or not.
    public func docRefresh(path: String) {
        send(.docRefresh(path: path))
    }

    /// issue #41: ask for one terminal's scrollback ring. Exactly one
    /// `scrollback` comes back, even for an unknown terminal — but a daemon that
    /// predates the type never answers, so the caller bounds its wait.
    public func scrollbackRequest(termID: String) {
        send(.scrollbackRequest(termID: termID))
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
        // A daemon that cannot log must still start, so a log that will not
        // open leaves stdio inherited.
        if let log = Self.openLog(at: DaemonLaunch.logPath(socketPath: socketPath)) {
            proc.standardOutput = log
            proc.standardError = log
        }
        // Hand the daemon (and the PTYs it spawns) a PATH that resolves the
        // `tarmac` CLI beside it, so `tarmac open` works inside the app's own
        // terminals even under a Finder launch (minimal launchd PATH).
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = DaemonLaunch.injectCLIPath(
            base: environment["PATH"],
            cliDir: DaemonLaunch.cliDir(forDaemon: binPath)
        )
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

    private func spawnedChild() -> Process? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return spawnedDaemon
    }

    /// Truncated per launch, so the file is bounded by one daemon session.
    private static func openLog(at path: String) -> FileHandle? {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: path, contents: nil) else { return nil }
        return FileHandle(forWritingAtPath: path)
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
