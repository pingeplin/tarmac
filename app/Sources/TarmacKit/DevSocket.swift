import Foundation

/// The QA driver's listening socket (spec 2609.0015, #166; parity rows Q3–Q5),
/// which the APP binds — the Swift twin of `claim_dev_socket` and
/// `serve_connection` in `desktop/src-tauri/src/dev_driver.rs`. Blocking I/O:
/// the app serves it from a thread of its own, one connection after another.
///
/// Deliberately NOT the daemon's claim rule. `tarmacd` exits when another
/// daemon holds its socket; the app must not, because losing the window over a
/// dev-only endpoint is worse than not having the endpoint. A live sibling
/// worktree's socket is left exactly as it was.
public final class DevSocket: @unchecked Sendable {
    public enum ClaimFailure: Error, Equatable {
        /// Something accepts connections on the path already.
        case liveOwner
        /// The path does not fit a `sockaddr_un`.
        case pathTooLong
        /// `socket`, `bind` or `listen` failed, with its `errno`.
        case system(Int32)
    }

    public let path: String
    let listener: Int32
    private let lock = NSLock()
    private var closed = false

    /// Binds `path`, replacing a leftover file only when nothing answers on it.
    public static func claim(path: String) -> Result<DevSocket, ClaimFailure> {
        guard DaemonClient.fitsUnixSocketPath(path) else { return .failure(.pathTooLong) }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: path) {
            if let probe = DaemonSocket.connect(to: path) {
                Darwin.close(probe)
                return .failure(.liveOwner)
            }
            unlink(path)
        }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return .failure(.system(errno)) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                _ = memcpy(dst.baseAddress!, src, strlen(src) + 1)
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // `bind` leaves whatever the umask allows.
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 8) == 0 else {
            let code = errno
            Darwin.close(listener)
            if bound == 0 { unlink(path) }
            return .failure(.system(code))
        }
        return .success(DevSocket(path: path, listener: listener))
    }

    private init(path: String, listener: Int32) {
        self.path = path
        self.listener = listener
    }

    deinit { close() }

    public enum Accepted: Equatable, Sendable {
        case connection(Int32)
        /// `close()` was called: there is nothing more to serve.
        case closed
        /// `accept` failed, with its `errno`. The socket has closed itself.
        case failed(Int32)
    }

    /// Blocks for the next connection.
    public func accept() -> Accepted {
        while true {
            // After `close()` the descriptor number may be someone else's.
            if lock.withLock({ closed }) { return .closed }
            let connection = Darwin.accept(listener, nil, nil)
            if connection < 0, errno == EINTR { continue }
            guard connection >= 0 else {
                let code = errno
                if lock.withLock({ closed }) { return .closed }
                // Dead from here on: left bound, callers would connect to it
                // and wait out their timeouts instead of failing at once.
                close()
                return .failed(code)
            }
            // A caller that gave up waiting has closed its end; the reply to it
            // must fail the write, not kill the app.
            var yes: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            return .connection(connection)
        }
    }

    /// Stops listening and removes the file, so the next run claims a free path
    /// rather than having to decide whether a leftover is stale.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(listener)
        unlink(path)
    }

    /// One request per connection: read a frame, answer it, close.
    ///
    /// A connection that ends before a whole frame arrives is dropped without a
    /// word: it is the liveness probe `claim` makes on a sibling, and there is
    /// nobody left to tell. An over-cap length is dropped the same way, before
    /// anything is allocated for it.
    public static func serve(_ connection: Int32, answer: (DevRequest) -> DevReply) {
        defer { Darwin.close(connection) }
        guard let payload = DaemonSocket.readFrame(from: connection) else { return }
        let reply: DevReply
        do {
            reply = answer(try DevRequest.decode(payload: payload))
        } catch {
            reply = DevError(.badRequest, "undecodable frame: \(error)").reply
        }
        guard let frame = try? Framing.frame(reply.encodedPayload()) else { return }
        _ = DaemonSocket.write(frame, to: connection)
    }
}
