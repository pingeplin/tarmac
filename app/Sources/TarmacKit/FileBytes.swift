import Foundation

/// A card's file, read as the Tauri backend's `std::fs::read` reads it: the
/// path exactly as named, with POSIX `open`. `URL(fileURLWithPath:)` drops a
/// trailing slash, which names a directory and must fail.
public enum FileBytes {
    /// An `errno`, worded as Rust's `io::Error` words it — the text a card
    /// shows when its file cannot be read.
    public struct ReadError: LocalizedError, Equatable, Sendable {
        public let code: Int32

        public var errorDescription: String? {
            "\(String(cString: strerror(code))) (os error \(code))"
        }
    }

    /// The path names something with no end to read to: a device, a pipe, a
    /// socket. `std::fs::read` would read it; a card that sends itself to
    /// `/dev/zero` must not be able to make the app do so.
    public struct NotAFile: LocalizedError, Equatable, Sendable {
        public var errorDescription: String? { "not a regular file" }
    }

    /// The path of the file `path` leads to, every symlink followed. It fails
    /// as reading `path` would when it leads nowhere.
    public static func resolved(path: String) -> Result<String, any Error> {
        guard let file = realpath(path, nil) else { return .failure(ReadError(code: errno)) }
        defer { free(file) }
        return .success(String(cString: file))
    }

    /// The file is larger than the app will hold. `std::fs::read` has no such
    /// limit; a card is not trusted with how much memory it takes.
    public struct TooLarge: LocalizedError, Equatable, Sendable {
        public let limit: Int

        public var errorDescription: String? { "too large: over \(limit) bytes" }
    }

    /// The largest file that is read: 64 MiB. A file is held in memory whole,
    /// and again by WebKit once it is served, so the limit is what bounds a
    /// card that names a huge or a sparse file. The largest things a card
    /// really is — a page with its assets inlined, a long animated GIF, a
    /// full-screen capture — run to tens of megabytes.
    public static let sizeCap = 64 << 20

    /// Blocks; call it off the main thread.
    public static func read(path: String) -> Result<Data, any Error> {
        read(path: path, limit: sizeCap)
    }

    static func read(path: String, limit: Int) -> Result<Data, any Error> {
        switch openRegular(path: path, limit: limit) {
        case .failure(let error):
            return .failure(error)
        case .success(let fd):
            defer { close(fd) }
            return bytes(of: fd, atMost: limit)
        }
    }

    /// A descriptor on `path`, which the caller closes: a regular file no
    /// larger than `limit`, to be read blocking.
    static func openRegular(path: String, limit: Int = sizeCap) -> Result<Int32, any Error> {
        // Non-blocking, so opening a pipe nobody writes to returns at once
        // and is then refused.
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return .failure(ReadError(code: errno)) }
        if let refusal = refusal(of: fd, limit: limit) ?? madeBlocking(fd) {
            close(fd)
            return .failure(refusal)
        }
        return .success(fd)
    }

    /// Why the open file is not read, judged on what the system says of it
    /// before any of it is read; nil if it may be.
    private static func refusal(of fd: Int32, limit: Int) -> (any Error)? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return ReadError(code: errno) }
        switch info.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFDIR: return ReadError(code: EISDIR)
        default: return NotAFile()
        }
        return info.st_size <= limit ? nil : TooLarge(limit: limit)
    }

    /// The non-blocking flag was for the open alone: a read of the file waits
    /// for its bytes.
    private static func madeBlocking(_ fd: Int32) -> (any Error)? {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { return ReadError(code: errno) }
        return nil
    }

    /// Everything `fd` has to give, refused once it is more than `limit`: the
    /// size a file had when it was opened does not bound what it holds by the
    /// time it is read.
    static func bytes(of fd: Int32, atMost limit: Int) -> Result<Data, any Error> {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(ReadError(code: errno))
            }
            if count == 0 { return .success(data) }
            data.append(chunk, count: count)
            if data.count > limit { return .failure(TooLarge(limit: limit)) }
        }
    }
}
