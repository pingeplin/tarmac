import Darwin

/// A process's physical footprint: the figure Activity Monitor and `top` show
/// as its memory, not its resident size. It reads this process and any other
/// of the same user with no entitlement (spec 2611.0004).
public enum ProcessFootprint {
    /// Nil when the call fails: no such process, or another user's.
    public static func bytes(of pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }
}
