import Foundation

/// Launches the daemon so that it outlives the app and owes it nothing: its own
/// session, no descriptor of the app's, a clean signal state, and its output in
/// a log file. `posix_spawn` rather than `Process`, which can neither start a
/// session nor hand back a child it does not also wait on.
public enum DaemonSpawner {
    /// The child's pid, or nil when nothing was launched. `environment` is the
    /// child's whole environment. `logPath` receives stdout and stderr, truncated
    /// per launch so the file is bounded by one daemon session; if it cannot be
    /// opened the daemon still starts, on the app's own stdout and stderr — a bad
    /// log directory must never cost the daemon.
    public static func spawn(
        program: String,
        arguments: [String] = [],
        environment: [String: String],
        logPath: String
    ) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        let log = openLog(at: logPath)
        defer { if log >= 0 { close(log) } }
        for stream in [STDOUT_FILENO, STDERR_FILENO] {
            if log >= 0 {
                posix_spawn_file_actions_adddup2(&actions, log, stream)
            } else {
                posix_spawn_file_actions_addinherit_np(&actions, stream)
            }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // SETSID: a SIGHUP aimed at the launching terminal's session — which a
        // new process group alone would not escape — never reaches the daemon.
        // CLOEXEC_DEFAULT: only the three streams above cross over.
        // SETSIGMASK / SETSIGDEF: blocked and ignored signals survive exec, and
        // the daemon must see the SIGTERM a version-mismatch restart sends it
        // whatever the spawning thread had masked.
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)

        let argv = cStrings([program] + arguments)
        let envp = cStrings(environment.map { "\($0.key)=\($0.value)" })
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, program, &actions, &attributes, argv, envp) == 0 else { return nil }
        return pid
    }

    /// `waitpid(pid, WNOHANG)`: 0 while the child runs, its pid once it has
    /// exited (which also reaps it), -1 when it is not ours to ask about. Feeds
    /// `DaemonLaunch.priorChildExited`. Not `kill(pid, 0)`, which still succeeds
    /// on a zombie.
    public static func waitResult(of pid: pid_t) -> Int32 {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG)
    }

    private static func openLog(at path: String) -> Int32 {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    }

    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }
}
