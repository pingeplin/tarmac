import Foundation

/// Blocking I/O on the daemon's Unix stream socket: connect, one
/// length-prefixed frame in, bytes out. No policy lives here — `DaemonClient`
/// decides when to connect, what a dead socket means, and who may write.
enum DaemonSocket {
    /// A connected descriptor, or nil.
    static func connect(to path: String) -> Int32? {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = address(of: path)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(sock)
            return nil
        }
        return sock
    }

    /// `path` as a socket address. It must fit a `sockaddr_un`
    /// (`DaemonClient.fitsUnixSocketPath`): it is copied, never truncated.
    static func address(of path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                // predates the lint; decided in #476
                // swift-format-ignore: NeverForceUnwrap
                _ = memcpy(dst.baseAddress!, src, strlen(src) + 1)
            }
        }
        return addr
    }

    /// The next frame's payload, or nil once the stream is unusable: EOF, a
    /// socket error, or a length past the 16 MiB cap, after which the frame
    /// boundaries are lost.
    static func readFrame(from fd: Int32) -> Data? {
        guard let header = readExact(4, from: fd) else { return nil }
        let length = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
        guard length <= Framing.maxFrameLength, let payload = readExact(length, from: fd) else { return nil }
        return Data(payload)
    }

    /// Whether `fd` has bytes to read, or has ended, within `seconds`.
    static func waitReadable(_ fd: Int32, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let left = max(0, deadline.timeIntervalSinceNow)
            let n = poll(&entry, 1, Int32((left * 1000).rounded(.up)))
            if n < 0, errno == EINTR { continue }
            return n > 0
        }
    }

    /// Whether all of `data` was written.
    static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                // raw is not empty here: the loop runs only while offset < raw.count
                // swift-format-ignore: NeverForceUnwrap
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    private static func readExact(_ count: Int, from fd: Int32) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            // buffer is not empty here: it holds count bytes and the loop runs only while got < count
            // swift-format-ignore: NeverForceUnwrap
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: got), count - got) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            got += n
        }
        return buffer
    }
}
