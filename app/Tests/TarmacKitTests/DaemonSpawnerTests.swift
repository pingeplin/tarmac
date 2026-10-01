import XCTest
import TarmacKit

/// Blocks until `pid` exits and returns its raw wait status.
private func reap(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    return status
}

private func exitCode(_ status: Int32) -> Int32? {
    status & 0x7f == 0 ? (status >> 8) & 0xff : nil
}

private func terminatingSignal(_ status: Int32) -> Int32? {
    let signal = status & 0x7f
    return signal != 0 && signal != 0x7f ? signal : nil
}

/// How the daemon is launched, observed from real children. The first five are
/// the Rust `daemon_command_*` tests in `desktop/src-tauri/src/bridge.rs`.
final class DaemonSpawnerTests: XCTestCase {
    private var dir = ""
    private var log: String { dir + "/tarmacd.log" }

    override func setUp() {
        dir = NSTemporaryDirectory() + "tarmac-spawner-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func sh(_ script: String, environment: [String: String] = [:], logPath: String? = nil) throws -> pid_t {
        try XCTUnwrap(DaemonSpawner.spawn(
            program: "/bin/sh", arguments: ["-c", script], environment: environment, logPath: logPath ?? log
        ))
    }

    private func logText(_ path: String? = nil) -> String {
        (try? String(contentsOfFile: path ?? log, encoding: .utf8)) ?? ""
    }

    /// Sends `pid` SIGTERM and reaps it; a child that outlives that is killed.
    private func assertSIGTERMKills(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        kill(pid, SIGTERM)
        let died = expectation(description: "the child died of SIGTERM")
        DispatchQueue.global().async {
            if terminatingSignal(reap(pid)) == SIGTERM { died.fulfill() }
        }
        if XCTWaiter().wait(for: [died], timeout: 2) != .completed {
            kill(pid, SIGKILL)
            XCTFail("the child never saw SIGTERM", file: file, line: line)
        }
    }

    /// The spawned daemon is its own session leader, so a session-wide SIGHUP
    /// aimed at the launching terminal cannot reach it.
    func testTheDaemonStartsItsOwnSession() throws {
        let pid = try XCTUnwrap(DaemonSpawner.spawn(
            program: "/bin/sleep", arguments: ["30"], environment: [:], logPath: log
        ))
        defer {
            kill(pid, SIGKILL)
            _ = reap(pid)
        }
        XCTAssertEqual(getsid(pid), pid, "daemon must be a session leader")
        XCTAssertNotEqual(getsid(pid), getsid(0), "daemon must leave our session")
    }

    /// Both streams land in the log, and its directory is created on the way.
    func testBothStreamsAreLoggedIntoACreatedDirectory() throws {
        let nested = dir + "/not-yet/tarmacd.log"
        _ = reap(try sh("echo out; echo err >&2", logPath: nested))

        let body = logText(nested)
        XCTAssertTrue(body.contains("out"), "stdout must be redirected, log was \(body)")
        XCTAssertTrue(body.contains("err"), "stderr must be redirected, log was \(body)")
    }

    /// Each launch truncates: the file is bounded by one daemon session.
    func testTheLogIsTruncatedPerLaunch() throws {
        for marker in ["FIRST-MARKER-WITH-PADDING", "SECOND"] {
            _ = reap(try sh("echo \(marker)"))
        }
        XCTAssertEqual(logText(), "SECOND\n")
    }

    /// An unopenable log path costs the log, never the daemon.
    func testTheDaemonStillRunsWhenTheLogCannotBeOpened() throws {
        XCTAssertEqual(exitCode(reap(try sh("exit 7", logPath: dir))), 7)
    }

    /// The child's environment is the one handed over, observed from the child.
    func testTheChildSeesTheEnvironmentItWasGiven() throws {
        _ = reap(try sh("printenv PATH; printenv MARK", environment: ["PATH": "/x/bin:/usr/bin:/bin", "MARK": "m"]))
        XCTAssertEqual(logText(), "/x/bin:/usr/bin:/bin\nm\n")
    }

    /// The daemon must not hold the launching terminal's stdin.
    func testStdinIsTheNullDevice() throws {
        _ = reap(try sh("[ /dev/fd/0 -ef /dev/null ] && echo null-stdin"))
        XCTAssertEqual(logText(), "null-stdin\n")
    }

    /// Only stdio crosses into the daemon. A descriptor the app happens to hold
    /// open — its sockets, a pipe to whatever launched it — would otherwise live
    /// on in a process meant to outlive the app.
    func testNoOtherDescriptorIsInherited() throws {
        let held = fcntl(open("/dev/null", O_RDONLY), F_DUPFD, 64)
        XCTAssertGreaterThanOrEqual(held, 64)
        defer { close(held) }

        _ = reap(try sh("[ -e /dev/fd/\(held) ] && echo leaked; echo done"))
        XCTAssertEqual(logText(), "done\n")
    }

    /// A blocked signal survives exec, and the app spawns from a thread that may
    /// well have some blocked: the daemon would then never see the SIGTERM a
    /// version-mismatch restart sends it.
    func testTheDaemonDoesNotInheritABlockedSignalMask() throws {
        var blocked = sigset_t()
        var previous = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTERM)
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        let spawned = DaemonSpawner.spawn(program: "/bin/sleep", arguments: ["30"], environment: [:], logPath: log)
        pthread_sigmask(SIG_SETMASK, &previous, nil)

        assertSIGTERMKills(try XCTUnwrap(spawned))
    }

    /// An ignored signal survives exec too, and the app inherits those from
    /// whatever launched it: a daemon ignoring SIGTERM could never be replaced.
    func testTheDaemonDoesNotInheritAnIgnoredSignal() throws {
        let previous = signal(SIGTERM, SIG_IGN)
        let spawned = DaemonSpawner.spawn(program: "/bin/sleep", arguments: ["30"], environment: [:], logPath: log)
        signal(SIGTERM, previous)

        assertSIGTERMKills(try XCTUnwrap(spawned))
    }

    /// A spawn that produced no child reports none, so the caller never latches
    /// onto a daemon that does not exist.
    func testAProgramThatCannotBeLaunchedYieldsNoChild() {
        XCTAssertNil(DaemonSpawner.spawn(
            program: dir + "/no-such-tarmacd", environment: [:], logPath: log
        ))
    }

    /// The observation `DaemonLaunch.priorChildExited` is fed, on real children.
    func testWaitResultTellsALiveChildFromADeadOne() throws {
        let live = try XCTUnwrap(DaemonSpawner.spawn(
            program: "/bin/sleep", arguments: ["30"], environment: [:], logPath: log
        ))
        XCTAssertFalse(DaemonLaunch.priorChildExited(waitResult: DaemonSpawner.waitResult(of: live)))

        kill(live, SIGKILL)
        let deadline = Date().addingTimeInterval(2)
        var result = DaemonSpawner.waitResult(of: live)
        while result == 0, Date() < deadline {
            usleep(10_000)
            result = DaemonSpawner.waitResult(of: live)
        }
        XCTAssertEqual(result, live, "the dead child is reaped by the observation")
        XCTAssertTrue(DaemonLaunch.priorChildExited(waitResult: result))
        XCTAssertTrue(DaemonLaunch.priorChildExited(waitResult: DaemonSpawner.waitResult(of: live)))
    }
}
