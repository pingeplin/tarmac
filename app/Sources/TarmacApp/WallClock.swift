import Foundation

/// The wall clock in whole milliseconds since the epoch: the clock a report's
/// `at_ms` and a doc's `last_changed_ms` are read against.
enum WallClock {
    static var nowMs: UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
}
