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

    /// Blocks; call it off the main thread.
    public static func read(path: String) -> Result<Data, any Error> {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .failure(ReadError(code: errno)) }
        defer { close(fd) }

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
