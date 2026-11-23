import XCTest

@testable import TarmacKit

/// The fence every signal of a test goes through (spec 2611.0033).
final class OwnChildTests: XCTestCase {
    private func child() throws -> pid_t {
        try XCTUnwrap(
            DaemonSpawner.spawn(program: "/bin/sleep", arguments: ["30"], environment: [:], logPath: "/dev/null"))
    }

    /// S4: a pid that is not a child of this process is recorded and refused,
    /// and nothing is delivered.
    func testAPidThatIsNotAChildOfTheTestIsRefused() throws {
        let reaped = try child()
        XCTAssertTrue(OwnChild.signal(reaped, SIGKILL))
        _ = reap(reaped)
        let delivered = Log<pid_t>()
        let fence = FencedSignal { pid, _ in delivered.record(pid) }

        let foreign: [pid_t] = [0, 1, -1, -getpid(), getpid(), getppid(), reaped]
        for pid in foreign { fence.send(pid, SIGTERM) }

        let asked = foreign.map { FencedSignal.Request(pid: $0, signal: SIGTERM) }
        XCTAssertEqual(fence.requests, asked)
        XCTAssertEqual(fence.refused, asked)
        XCTAssertEqual(delivered.all, [])
        for pid in foreign { XCTAssertFalse(OwnChild.signal(pid, 0), "pid \(pid)") }
    }

    /// S5: a live child of this process gets the signal.
    func testAChildOfTheTestGetsTheSignal() throws {
        let pid = try child()
        let fence = FencedSignal()

        fence.send(pid, SIGTERM)

        XCTAssertEqual(terminatingSignal(reap(pid)), SIGTERM)
        XCTAssertEqual(fence.requests, [.init(pid: pid, signal: SIGTERM)])
        XCTAssertEqual(fence.refused, [])
    }
}
