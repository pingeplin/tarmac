import Foundation

/// Pure decisions for launching the bundled daemon and giving its PTYs a `PATH`
/// that resolves the `tarmac` CLI. Kept in TarmacKit so the rules are unit-tested
/// away from Foundation I/O; `DaemonClient` and `DaemonSpawner` only do the
/// wiring — the filesystem check, the spawn, the signal.
///
/// Why this exists: shipped as a double-clickable `.app`, Tarmac no longer has
/// the `make run` environment. A Finder-launched bundle has no `TARMAC_DAEMON`
/// and inherits only the minimal launchd `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`),
/// which contains no `tarmac`. See spec 2606.0002.
public enum DaemonLaunch {
    /// Which daemon binary a connect miss spawns, or `nil` if there is none.
    ///
    /// - A non-empty `TARMAC_DAEMON` wins verbatim and is never probed (`!isEmpty`,
    ///   no trimming — so a whitespace-only value counts as set). This is what
    ///   `make run` uses to name a debug build.
    /// - Otherwise the `tarmacd` beside the running executable, iff `exists`
    ///   reports it. A bundle keeps both in `Contents/MacOS`.
    public static func resolveDaemonPath(
        env: [String: String],
        executableDir: String,
        exists: (String) -> Bool
    ) -> String? {
        if let override = env["TARMAC_DAEMON"], !override.isEmpty {
            return override
        }
        let sibling = (executableDir as NSString).appendingPathComponent("tarmacd")
        return exists(sibling) ? sibling : nil
    }

    // MARK: - Stale-daemon restart (ports of `desktop/src-tauri/src/bridge.rs`)

    /// Whether to replace the daemon a handshake just answered from. `expected`
    /// is the app's own version, `reported` is `hello_ok.daemon_version`: a
    /// different version, or none (a daemon that predates the key), is stale.
    /// `alreadyRestarted` is a once-per-process latch — when the respawned daemon
    /// STILL mismatches (bad PATH, stale install) the app proceeds against it
    /// rather than killing daemons in a loop. An app that knows no version of its
    /// own (`AppVersion`) has nothing to compare, so it never restarts.
    public static func shouldRestart(expected: String?, reported: String?, alreadyRestarted: Bool) -> Bool {
        guard let expected else { return false }
        return reported != expected && !alreadyRestarted
    }

    /// Which pid the restart SIGTERMs. `hello_ok.daemon_pid` wins: after an
    /// upgrade the stale daemon was started by the previous app, so the child
    /// this app tracks is not the process the handshake came from. The tracked
    /// child is the fallback for a daemon too old to report a pid.
    ///
    /// The result goes to kill(2), where 0 and negatives address process groups
    /// (-1: everything the user owns) and 1 is launchd, so only a pid that names
    /// one ordinary process is ever returned.
    public static func restartTarget(reportedPid: Int?, spawnedChildPid: Int?) -> Int? {
        func oneProcess(_ pid: Int?) -> Int? {
            guard let pid, pid > 1, pid <= Int(Int32.max) else { return nil }
            return pid
        }
        return oneProcess(reportedPid) ?? oneProcess(spawnedChildPid)
    }

    /// The daemon a version-mismatch restart replaced, kept so the app can tell
    /// the user their terminals were lost to an upgrade. `to` is what the next
    /// proceeding connection reported — not the app's own version — so a respawn
    /// that still mismatches is named as what it is.
    public struct Replaced: Equatable, Sendable {
        public var from: String?
        public var to: String?

        public init(from: String?, to: String?) {
            self.from = from
            self.to = to
        }
    }

    /// A connection that got past the version check fills an open `to`. The
    /// first reported version sticks; an unreported one leaves it open.
    public static func noteProceeding(_ record: inout Replaced?, reported: String?) {
        guard record != nil, record?.to == nil else { return }
        record?.to = reported
    }

    /// May a daemon be spawned on this connect pass? The latch only stops a
    /// second daemon piling onto one just started, so it holds only while that
    /// child is alive. The caller passes `priorChildExited: true` whenever it
    /// cannot tell: an unknown state must never lock the app out for good.
    public static func maySpawn(alreadySpawned: Bool, priorChildExited: Bool) -> Bool {
        !alreadySpawned || priorChildExited
    }

    /// "No live child we spawned", from what `waitpid(pid, WNOHANG)` said about
    /// it (`nil`: no child was ever produced). Only an observed-live child — a
    /// result of 0 — blocks a respawn. A reaped child returns its pid, and -1 is
    /// the "cannot tell" case: answering that with `false` would lock the app out
    /// for good, where erring the other way costs at most one extra spawn per
    /// pass, bounded by the reconnect budget.
    public static func priorChildExited(waitResult: Int32?) -> Bool {
        waitResult != 0
    }

    /// The directory to put on the daemon's `PATH` (see `injectCLIPath`): the
    /// daemon's own. The bundle places `tarmac` beside `tarmacd`, and so does a
    /// cargo build dir named by `TARMAC_DAEMON`, so the PTYs resolve the CLI that
    /// matches the daemon either way.
    public static func cliDir(forDaemon daemonPath: String) -> String {
        (daemonPath as NSString).deletingLastPathComponent
    }

    /// The environment the daemon is launched with: the app's own, with the
    /// daemon's directory on `PATH` (see `injectCLIPath`). The PTYs the daemon
    /// spawns inherit it, which is how `tarmac open` resolves inside a terminal
    /// card even under a Finder launch.
    public static func childEnvironment(base: [String: String], daemonPath: String) -> [String: String] {
        var environment = base
        environment["PATH"] = injectCLIPath(base: base["PATH"], cliDir: cliDir(forDaemon: daemonPath))
        return environment
    }

    /// Where the spawned daemon's stdout/stderr go: `tarmacd.log` beside the
    /// socket — the one path that already separates a dev app from the installed
    /// one.
    public static func logPath(socketPath: String) -> String {
        ((socketPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("tarmacd.log")
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
