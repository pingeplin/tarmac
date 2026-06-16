import Foundation

/// Pure decisions for launching the bundled daemon and giving its PTYs a `PATH`
/// that resolves the `tarmac` CLI. Kept in TarmacKit so the rules are unit-tested
/// away from AppKit/Foundation I/O; `DaemonClient` (`connect` / `spawnDaemon`)
/// only does the wiring — the filesystem existence check and the
/// `proc.environment` assignment. Mirrors the `TermExit` / `TermRestore.plan()`
/// pattern.
///
/// Why this exists: shipped as a double-clickable `.app`, Tarmac no longer has
/// the `make run` environment. A Finder-launched bundle has no `TARMAC_DAEMON`
/// and inherits only the minimal launchd `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`),
/// which contains no `tarmac`. See spec 2606.0002.
public enum DaemonLaunch {
    /// Which daemon binary `connect` should spawn, or `nil` if none is resolvable
    /// (the caller then keeps today's helpful `connectFailed`).
    ///
    /// Pure: the FILESYSTEM existence check is the caller's job, passed in as
    /// `bundledBinaryExists`, so this stays testable away from disk.
    ///
    /// - An explicit `TARMAC_DAEMON` (non-empty, `!isEmpty`, no trimming — so a
    ///   whitespace-only value counts as set, matching the old `!daemonBin.isEmpty`)
    ///   wins UNCONDITIONALLY and is returned verbatim; `bundledBinaryExists` is
    ///   ignored. This preserves `make run`, which points it at a debug build.
    /// - Otherwise the bundled path `<bundleURL>/Contents/MacOS/tarmacd` is
    ///   returned iff `bundledBinaryExists`, else `nil`.
    public static func resolveDaemonPath(
        env: [String: String],
        bundleURL: URL,
        bundledBinaryExists: Bool
    ) -> String? {
        if let override = env["TARMAC_DAEMON"], !override.isEmpty {
            return override
        }
        guard bundledBinaryExists else { return nil }
        return bundleURL.appendingPathComponent("Contents/MacOS/tarmacd").path
    }

    /// The `PATH` to hand the spawned daemon so it — and the PTYs it spawns — can
    /// resolve `tarmac`. Prepends `cliDir` (the bundle's `Contents/MacOS`) as the
    /// first segment, leaving the inherited `PATH` otherwise untouched.
    ///
    /// - If `cliDir` already appears as an EXACT colon-delimited segment anywhere
    ///   in `base`, `base` is returned UNCHANGED — no duplicate, no reorder, so the
    ///   function is idempotent and never shadows a `PATH` the user/admin ordered.
    /// - A substring is not a segment: a `base` entry of `/x/binfoo` does not count
    ///   as already containing `cliDir` `/x/bin`.
    /// - `nil`/empty `base` → just `cliDir`. Existing empty segments (leading or
    ///   trailing colons) are preserved verbatim. Defensive: an empty `cliDir` is
    ///   never prepended (it would introduce a stray leading colon), so `base` is
    ///   returned unchanged (`nil` → `""`).
    public static func injectCLIPath(base: String?, cliDir: String) -> String {
        guard !cliDir.isEmpty else { return base ?? "" }
        guard let base, !base.isEmpty else { return cliDir }
        let segments = base.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if segments.contains(cliDir) { return base }
        return cliDir + ":" + base
    }
}
