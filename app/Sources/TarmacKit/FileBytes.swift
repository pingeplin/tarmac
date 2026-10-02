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

    /// Blocks; call it off the main thread.
    public static func read(path: String) -> Result<Data, any Error> {
        // Non-blocking, so opening a pipe nobody writes to returns at once
        // and is then refused. It changes nothing for a regular file.
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return .failure(ReadError(code: errno)) }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(ReadError(code: errno)) }
        switch info.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFDIR: return .failure(ReadError(code: EISDIR))
        default: return .failure(NotAFile())
        }

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
        }
    }
}
