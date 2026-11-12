import Foundation

/// The app's sample log, `tarmac-app.jsonl` beside the daemon socket, so one
/// file for each channel, next to `tarmacd.log` (spec 2611.0004). The app is
/// long-lived, so the size is checked before every append, not only at
/// launch. Unlike `tarmacd.log` no directory is made: `make run` makes the
/// dev channel's, and a daemon spawn makes the socket's (`DaemonSpawner`). A
/// line with nowhere to go is dropped.
public enum SampleLogFile {
    public static let cap = 1 << 20

    public static func path(socketPath: String) -> String {
        ((socketPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("tarmac-app.jsonl")
    }

    /// Writes `line` and a newline. A file larger than `cap` is first moved to
    /// `<path>.1`, replacing an older one; a failed move or open drops the line.
    public static func append(_ line: String, to path: String, cap: Int = cap) {
        var info = stat()
        if stat(path, &info) == 0, info.st_size > off_t(cap) {
            guard rename(path, path + ".1") == 0 else { return }
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array((line + "\n").utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            written += count
        }
    }
}
