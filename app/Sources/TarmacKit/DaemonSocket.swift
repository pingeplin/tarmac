import Foundation

/// Blocking I/O on the daemon's Unix stream socket: connect, one
/// length-prefixed frame in, bytes out. No policy lives here — `DaemonClient`
/// decides when to connect, what a dead socket means, and who may write.
enum DaemonSocket {
    /// A connected descriptor, or nil. `path` must fit a `sockaddr_un`
    /// (`DaemonClient.fitsUnixSocketPath`): it is copied, never truncated.
    static func connect(to path: String) -> Int32? {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                _ = memcpy(dst.baseAddress!, src, strlen(src) + 1)
            }
        }
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

    /// The next frame's payload, or nil once the stream is unusable: EOF, a
    /// socket error, or a length past the 16 MiB cap, after which the frame
    /// boundaries are lost.
    static func readFrame(from fd: Int32) -> Data? {
        guard let header = readExact(4, from: fd) else { return nil }
        let length = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
        guard length <= Framing.maxFrameLength, let payload = readExact(length, from: fd) else { return nil }
        return Data(payload)
    }

    /// Whether all of `data` was written.
    static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
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
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: got), count - got) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            got += n
        }
        return buffer
    }
}
