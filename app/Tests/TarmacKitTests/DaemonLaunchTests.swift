import XCTest
@testable import TarmacKit

/// 2606.0002: bundled-daemon-path resolution and PTY `PATH` injection.
final class DaemonLaunchTests: XCTestCase {
    private let macOS = "/A/Tarmac.app/Contents/MacOS"
    private var siblingDaemon: String { "/A/Tarmac.app/Contents/MacOS/tarmacd" }

    // MARK: - resolveDaemonPath

    /// S1, S2, S4, S5, S11, S13: the full resolution grid. Columns are the env
    /// value for `TARMAC_DAEMON` (`nil` = key absent) and whether a `tarmacd`
    /// sits beside the running executable. The explicit override must win
    /// VERBATIM and UNCONDITIONALLY — even with no sibling (S1) and even when one
    /// exists (S5) — while an absent or empty override falls through to the
    /// sibling (S2/S4) or `nil` (S11). S13 pins that "non-empty" is `!isEmpty`
    /// with no trimming: a whitespace-only override is honored verbatim.
    func testResolveDaemonPathGrid() {
        let cases: [(override: String?, exists: Bool, expected: String?)] = [
            ("/dbg/tarmacd", false, "/dbg/tarmacd"),
            (nil, true, "/A/Tarmac.app/Contents/MacOS/tarmacd"),
            ("", true, "/A/Tarmac.app/Contents/MacOS/tarmacd"),
            ("/dbg/tarmacd", true, "/dbg/tarmacd"),
            (nil, false, nil),
            ("   ", true, "   "),
        ]
        for c in cases {
            var env: [String: String] = [:]
            if let override = c.override { env["TARMAC_DAEMON"] = override }
            XCTAssertEqual(
                DaemonLaunch.resolveDaemonPath(env: env, executableDir: macOS) { _ in c.exists },
                c.expected,
                "resolveDaemonPath(override: \(c.override.map { "\"\($0)\"" } ?? "nil"), exists: \(c.exists))"
            )
        }
    }

    /// The candidate is the `tarmacd` beside the running executable and nothing
    /// else: a bare SwiftPM binary finds one in its build directory, a bundle in
    /// `Contents/MacOS`. Guards a mutation that probes another name or directory.
    func testTheOnlyCandidateIsTheExecutablesSibling() {
        var probed: [String] = []
        let found = DaemonLaunch.resolveDaemonPath(env: [:], executableDir: "/repo/app/.build/debug") { path in
            probed.append(path)
            return path == "/repo/app/.build/debug/tarmacd"
        }
        XCTAssertEqual(found, "/repo/app/.build/debug/tarmacd")
        XCTAssertEqual(probed, ["/repo/app/.build/debug/tarmacd"])
    }

    /// An override is never checked against the disk: `make run` names a build
    /// that may not exist yet, and the spawn reports that itself.
    func testAnOverrideIsNotProbed() {
        let found = DaemonLaunch.resolveDaemonPath(env: ["TARMAC_DAEMON": "/x"], executableDir: macOS) { _ in
            XCTFail("an override must not touch the disk")
            return false
        }
        XCTAssertEqual(found, "/x")
    }

    // MARK: - injectCLIPath

    /// S3, S6, S7, S8, S9, S12: the injection grid over `(base, cliDir)`.
    /// `nil` base is covered separately in `testInjectNilBase` (the table can't
    /// hold `nil` cleanly alongside `""`).
    func testInjectCLIPathGrid() {
        let cases: [(base: String, cliDir: String, expected: String)] = [
            ("/usr/bin:/bin", "/opt/homebrew/bin", "/opt/homebrew/bin:/usr/bin:/bin"),     // S3: prepend
            ("/usr/bin:/opt/homebrew/bin", "/opt/homebrew/bin", "/usr/bin:/opt/homebrew/bin"), // S6: already present → unchanged
            ("", "/opt/homebrew/bin", "/opt/homebrew/bin"),                                 // S7: empty base
            ("/usr/bin:", "/x", "/x:/usr/bin:"),                                            // S8: trailing empty segment preserved
            ("/opt/homebrew/binfoo", "/opt/homebrew/bin", "/opt/homebrew/bin:/opt/homebrew/binfoo"), // S9: substring is not a segment
            ("/usr/bin:/bin", "", "/usr/bin:/bin"),                                         // S12: empty cliDir → unchanged
        ]
        for c in cases {
            XCTAssertEqual(
                DaemonLaunch.injectCLIPath(base: c.base, cliDir: c.cliDir),
                c.expected,
                "injectCLIPath(base: \"\(c.base)\", cliDir: \"\(c.cliDir)\")"
            )
        }
    }

    /// S7 / S12: a `nil` base yields just `cliDir`, and a `nil` base with an empty
    /// `cliDir` yields `""` — never a stray leading colon.
    func testInjectNilBase() {
        XCTAssertEqual(DaemonLaunch.injectCLIPath(base: nil, cliDir: "/opt/homebrew/bin"), "/opt/homebrew/bin")
        XCTAssertEqual(DaemonLaunch.injectCLIPath(base: nil, cliDir: ""), "")
    }

    /// S6-vs-S9 boundary on its own: presence is decided by whole-segment equality,
    /// not substring containment. `/opt/homebrew/bin` is "present" in
    /// `/usr/bin:/opt/homebrew/bin` (unchanged) but NOT in `/opt/homebrew/binfoo`
    /// (prepended). A `base.contains(cliDir)` mutation collapses the two.
    func testSegmentMatchNotSubstring() {
        XCTAssertEqual(
            DaemonLaunch.injectCLIPath(base: "/usr/bin:/opt/homebrew/bin", cliDir: "/opt/homebrew/bin"),
            "/usr/bin:/opt/homebrew/bin"
        )
        XCTAssertEqual(
            DaemonLaunch.injectCLIPath(base: "/opt/homebrew/binfoo", cliDir: "/opt/homebrew/bin"),
            "/opt/homebrew/bin:/opt/homebrew/binfoo"
        )
    }

    /// S10: idempotency across every branch — applying `injectCLIPath` to its own
    /// output changes nothing. This is the property that the dedup must satisfy;
    /// dropping the segment check makes the prepend branch grow on every call and
    /// breaks the first case here.
    func testInjectCLIPathIdempotent() {
        let inputs: [(base: String, cliDir: String)] = [
            ("/usr/bin:/bin", "/opt/homebrew/bin"),       // prepend branch
            ("/usr/bin:/opt/homebrew/bin", "/opt/homebrew/bin"), // already-present branch
            ("", "/opt/homebrew/bin"),                     // empty-base branch
            ("/opt/homebrew/binfoo", "/opt/homebrew/bin"), // substring branch
            ("/usr/bin:", "/x"),                           // trailing-colon branch
        ]
        for input in inputs {
            let once = DaemonLaunch.injectCLIPath(base: input.base, cliDir: input.cliDir)
            let twice = DaemonLaunch.injectCLIPath(base: once, cliDir: input.cliDir)
            XCTAssertEqual(twice, once, "not idempotent for base \"\(input.base)\", cliDir \"\(input.cliDir)\"")
        }
    }

    // MARK: - childEnvironment

    /// The daemon inherits the app's environment with one change: its own
    /// directory leads `PATH`, so the PTYs it spawns resolve the `tarmac` CLI
    /// that sits beside it.
    func testTheDaemonsEnvironmentIsTheAppsWithTheCLIOnPath() {
        XCTAssertEqual(
            DaemonLaunch.childEnvironment(
                base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/x", "TARMAC_SOCKET": "/repo/.dev/tarmacd.sock"],
                daemonPath: "/repo/core/target/debug/tarmacd"
            ),
            [
                "PATH": "/repo/core/target/debug:/usr/bin:/bin",
                "HOME": "/Users/x",
                "TARMAC_SOCKET": "/repo/.dev/tarmacd.sock",
            ]
        )
    }

    /// A Finder launch can hand over no `PATH` at all; one already naming the
    /// directory is left as the user ordered it.
    func testTheDaemonsPathIsInjectedOnceAndCreatedWhenMissing() {
        XCTAssertEqual(
            DaemonLaunch.childEnvironment(base: [:], daemonPath: "/A/Tarmac.app/Contents/MacOS/tarmacd"),
            ["PATH": "/A/Tarmac.app/Contents/MacOS"]
        )
        XCTAssertEqual(
            DaemonLaunch.childEnvironment(base: ["PATH": "/usr/bin:/x/bin"], daemonPath: "/x/bin/tarmacd"),
            ["PATH": "/usr/bin:/x/bin"]
        )
    }

    // MARK: - shouldRestart

    /// The stale-daemon restart decision, as `bridge.rs` makes it: restart when
    /// the daemon reports another version or none at all, but only once — the
    /// latch stops a respawn that still mismatches from thrashing.
    func testShouldRestartGrid() {
        let cases: [(expected: String, reported: String?, already: Bool, restart: Bool)] = [
            ("0.1.0", "0.1.0", false, false), // equal versions
            ("0.2.0", "0.1.0", false, true),  // differing versions
            ("0.1.0", nil, false, true),      // a daemon that predates the key
            ("0.2.0", "0.1.0", true, false),  // already restarted once
            ("0.1.0", nil, true, false),
            ("0.1.0", "0.1.0", true, false),
        ]
        for c in cases {
            XCTAssertEqual(
                DaemonLaunch.shouldRestart(expected: c.expected, reported: c.reported, alreadyRestarted: c.already),
                c.restart,
                "shouldRestart(expected: \(c.expected), reported: \(c.reported ?? "nil"), already: \(c.already))"
            )
        }
    }

    /// An app that knows no version of its own cannot call any daemon stale: an
    /// unbundled dev binary with no `TARMAC_APP_VERSION` would otherwise kill
    /// the daemon on every launch.
    func testAnAppWithoutAVersionNeverRestarts() {
        XCTAssertFalse(DaemonLaunch.shouldRestart(expected: nil, reported: "0.1.0", alreadyRestarted: false))
        XCTAssertFalse(DaemonLaunch.shouldRestart(expected: nil, reported: nil, alreadyRestarted: false))
        XCTAssertFalse(DaemonLaunch.shouldRestart(expected: nil, reported: "0.1.0", alreadyRestarted: true))
    }

    /// The pid from `hello_ok` wins: after a brew upgrade the stale daemon was
    /// spawned by the PREVIOUS app, so the child this app tracks (if any) is not
    /// the one the handshake came from.
    /// The target is handed to kill(2), where 0 and negatives name process
    /// groups and -1 means every process the user owns.
    func testRestartTargetIsOnlyEverOneRealProcess() {
        for pid in [-1, 0, 1, Int(Int32.max) + 1] {
            XCTAssertNil(DaemonLaunch.restartTarget(reportedPid: pid, spawnedChildPid: nil), "\(pid)")
            XCTAssertEqual(DaemonLaunch.restartTarget(reportedPid: pid, spawnedChildPid: 99), 99, "\(pid)")
            XCTAssertNil(DaemonLaunch.restartTarget(reportedPid: nil, spawnedChildPid: pid), "\(pid)")
        }
    }

    func testRestartTargetPrefersTheReportedPid() {
        XCTAssertEqual(DaemonLaunch.restartTarget(reportedPid: 4242, spawnedChildPid: 99), 4242)
        XCTAssertEqual(DaemonLaunch.restartTarget(reportedPid: 4242, spawnedChildPid: nil), 4242)
        XCTAssertEqual(DaemonLaunch.restartTarget(reportedPid: nil, spawnedChildPid: 99), 99)
        XCTAssertNil(DaemonLaunch.restartTarget(reportedPid: nil, spawnedChildPid: nil))
    }

    // MARK: - noteProceeding

    func testNoteProceedingRecordsTheVersionTheRespawnReported() {
        var record: DaemonLaunch.Replaced? = DaemonLaunch.Replaced(from: "0.1.0", to: nil)
        DaemonLaunch.noteProceeding(&record, reported: "0.2.0")
        XCTAssertEqual(record, DaemonLaunch.Replaced(from: "0.1.0", to: "0.2.0"))
    }

    func testNoteProceedingWithoutARecordCreatesNone() {
        var record: DaemonLaunch.Replaced?
        DaemonLaunch.noteProceeding(&record, reported: "0.2.0")
        XCTAssertNil(record)
    }

    /// The first reported version sticks; an unreported one leaves `to` open for
    /// a later connection.
    func testNoteProceedingLeavesAFilledRecordUnchanged() {
        var filled: DaemonLaunch.Replaced? = DaemonLaunch.Replaced(from: "0.1.0", to: "0.2.0")
        DaemonLaunch.noteProceeding(&filled, reported: "0.3.0")
        XCTAssertEqual(filled, DaemonLaunch.Replaced(from: "0.1.0", to: "0.2.0"))

        var open: DaemonLaunch.Replaced? = DaemonLaunch.Replaced(from: nil, to: nil)
        DaemonLaunch.noteProceeding(&open, reported: nil)
        XCTAssertEqual(open, DaemonLaunch.Replaced(from: nil, to: nil))
    }

    // MARK: - maySpawn

    /// Spawn the first daemon, never pile a second onto a live one, and respawn
    /// once the child is gone — a spawn that died must not lock the app out.
    func testMaySpawnGrid() {
        XCTAssertTrue(DaemonLaunch.maySpawn(alreadySpawned: false, priorChildExited: true))
        XCTAssertTrue(DaemonLaunch.maySpawn(alreadySpawned: false, priorChildExited: false))
        XCTAssertFalse(DaemonLaunch.maySpawn(alreadySpawned: true, priorChildExited: false))
        XCTAssertTrue(DaemonLaunch.maySpawn(alreadySpawned: true, priorChildExited: true))
    }

    /// `waitResult` is what `waitpid(pid, WNOHANG)` returned for the child, nil
    /// when there is none. Only an observed-live child (0) blocks a respawn: a
    /// reaped child returns its pid, and an error (-1) is the "cannot tell" case
    /// that must never lock the app out.
    func testPriorChildExitedTruthTable() {
        XCTAssertTrue(DaemonLaunch.priorChildExited(waitResult: nil), "no child at all: the spawn itself failed")
        XCTAssertFalse(DaemonLaunch.priorChildExited(waitResult: 0))
        XCTAssertTrue(DaemonLaunch.priorChildExited(waitResult: 4242))
        XCTAssertTrue(DaemonLaunch.priorChildExited(waitResult: -1))
    }

    // MARK: - cliDir / logPath

    /// The `tarmac` CLI sits beside whichever daemon is launched — the bundle's
    /// `Contents/MacOS`, or the debug build dir a `TARMAC_DAEMON` override names.
    func testCLIDirIsTheDaemonsDirectory() {
        XCTAssertEqual(DaemonLaunch.cliDir(forDaemon: siblingDaemon), "/A/Tarmac.app/Contents/MacOS")
        XCTAssertEqual(DaemonLaunch.cliDir(forDaemon: "/repo/core/target/debug/tarmacd"), "/repo/core/target/debug")
        XCTAssertEqual(DaemonLaunch.cliDir(forDaemon: "tarmacd"), "")
    }

    /// `tarmacd.log` sits beside the socket, which is the one path that already
    /// separates a dev app from the installed one.
    func testLogPathSitsBesideTheSocket() {
        XCTAssertEqual(
            DaemonLaunch.logPath(socketPath: "/Users/x/Library/Application Support/tarmac/dev/tarmacd.sock"),
            "/Users/x/Library/Application Support/tarmac/dev/tarmacd.log"
        )
        XCTAssertEqual(DaemonLaunch.logPath(socketPath: "/repo/.dev/tarmacd.sock"), "/repo/.dev/tarmacd.log")
        XCTAssertEqual(DaemonLaunch.logPath(socketPath: "tarmacd.sock"), "tarmacd.log")
    }
}
