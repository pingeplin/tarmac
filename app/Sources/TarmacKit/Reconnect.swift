import Foundation

/// Pure backoff schedule for the app's bounded auto-reconnect (M3 P5.3). Kept in
/// TarmacKit so the schedule is unit-tested away from AppKit (mirrors
/// `TermRestore` / `BoardSwitcher`); `AppController` owns the AppKit timer +
/// `DaemonClient` orchestration, which is reviewed not unit-tested.
///
/// On a dropped daemon connection the app marks its sessions detached (faint, NOT
/// dead) and retries `connect()` on this schedule. A successful reconnect drives
/// the daemon's `board_list` + `restore` (with `liveTerms`), which re-binds the
/// still-live shells (revive) and cold-spawns the gone ones — reusing the same
/// rebind-vs-cold partition as [[TermRestore]]. The schedule is bounded twice
/// over: a capped per-attempt delay AND a capped attempt count, so a daemon that
/// never comes back surfaces a terminal "could not reconnect" notice rather than
/// retrying forever.
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
