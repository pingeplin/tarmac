import Foundation

/// The one place under `app/Tests` that calls kill(2) (`make arch-check`).
/// A pid in a test comes from code under test — a frame, a spawn, a decision —
/// so one wrong expression there would aim a signal at a process the test does
/// not own: -1 is every process of the user. A signal goes only to a child of
/// this process, as the kernel names its parent (#491).
enum OwnChild {
    static func isOne(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_ppid == UInt32(getpid())
    }

    /// Whether the signal was sent.
    @discardableResult
    static func signal(_ pid: pid_t, _ signal: Int32) -> Bool {
        guard isOne(pid) else { return false }
        kill(pid, signal)
        return true
    }
}

/// Blocks until `pid` exits and returns its raw wait status.
func reap(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    return status
}

func terminatingSignal(_ status: Int32) -> Int32? {
    let signal = status & 0x7f
    return signal != 0 && signal != 0x7f ? signal : nil
}

/// The sender a test gives a `DaemonClient`: every request is recorded, and
/// only one for a child of this process is delivered.
final class FencedSignal: @unchecked Sendable {
    struct Request: Equatable {
        var pid: pid_t
        var signal: Int32
    }

    private let lock = NSLock()
    private let deliver: @Sendable (pid_t, Int32) -> Void
    private var asked: [(request: Request, owned: Bool)] = []

    init(deliver: @escaping @Sendable (pid_t, Int32) -> Void = { OwnChild.signal($0, $1) }) {
        self.deliver = deliver
    }

    var requests: [Request] { lock.withLock { asked.map(\.request) } }
    var refused: [Request] { lock.withLock { asked.filter { !$0.owned }.map(\.request) } }

    func send(_ pid: pid_t, _ signal: Int32) {
        let owned = OwnChild.isOne(pid)
        lock.withLock { asked.append((Request(pid: pid, signal: signal), owned)) }
        if owned { deliver(pid, signal) }
    }
}
