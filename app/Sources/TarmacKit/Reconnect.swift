import Foundation

/// The backoff schedule `DaemonClient` retries a dropped daemon connection on.
/// It is bounded twice over — a capped per-attempt delay and a capped attempt
/// count — so a daemon that never comes back ends in a "could not reconnect"
/// status rather than retrying forever.
public enum Reconnect {
    /// How many attempts before giving up. Beyond this `delay` returns nil.
    public static let maxAttempts = 10
    /// The leading exponential ramp (seconds); attempts past it use `cap`.
    private static let ramp: [TimeInterval] = [0.5, 1, 2, 4, 8]
    /// The per-attempt delay ceiling (seconds) once the ramp tops out.
    private static let cap: TimeInterval = 15

    /// The delay (seconds) before attempt `n` (1-based), or nil once the attempt
    /// budget is spent (`n` < 1 or `n` > `maxAttempts`) — nil means "stop
    /// retrying". The schedule ramps 0.5→1→2→4→8 then holds at the 15 s `cap`, so
    /// it is monotonically non-decreasing and never exceeds `cap`.
    public static func delay(forAttempt n: Int) -> TimeInterval? {
        guard n >= 1, n <= maxAttempts else { return nil }
        return n <= ramp.count ? ramp[n - 1] : cap
    }
}
