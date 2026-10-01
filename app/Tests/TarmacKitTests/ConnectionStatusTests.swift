import XCTest
import TarmacKit

/// The exact status values `bridge.rs` emits and `App.tsx` starts from.
final class ConnectionStatusTests: XCTestCase {
    func testTheAppStartsOutConnecting() {
        XCTAssertEqual(ConnectionStatus.connecting, ConnectionStatus(connected: false, reason: "connecting…"))
    }

    func testAConnectedLinkCarriesNoReason() {
        XCTAssertEqual(ConnectionStatus.connected, ConnectionStatus(connected: true, reason: nil))
    }

    func testEveryDisconnectedReasonIsTheBridgesText() {
        XCTAssertEqual(ConnectionStatus.closed, ConnectionStatus(connected: false, reason: "daemon connection closed"))
        XCTAssertEqual(
            ConnectionStatus.restarting,
            ConnectionStatus(connected: false, reason: "version mismatch / restarting")
        )
        XCTAssertEqual(
            ConnectionStatus.gaveUp,
            ConnectionStatus(connected: false, reason: "could not reconnect to tarmacd")
        )
        XCTAssertEqual(
            ConnectionStatus.connectFailed("no daemon at /x/tarmacd.sock"),
            ConnectionStatus(connected: false, reason: "connect failed: no daemon at /x/tarmacd.sock")
        )
    }

    /// What the status bar prints for the link (`desktop/src/ui/StatusBar.tsx`).
    func testTheLabelIsAttachedOrTheReasonForNotBeing() {
        XCTAssertEqual(ConnectionStatus.connected.label, "attached")
        XCTAssertEqual(ConnectionStatus.connecting.label, "connecting…")
        XCTAssertEqual(ConnectionStatus.closed.label, "daemon connection closed")
        XCTAssertEqual(ConnectionStatus(connected: false, reason: nil).label, "detached")
    }

    func testAMissingDaemonIsNamedByItsSocket() {
        XCTAssertEqual(ConnectionStatus.noDaemon(at: "/repo/.dev/tarmacd.sock"), "no daemon at /repo/.dev/tarmacd.sock")
    }

    /// `tarmac_protocol::check_socket_path_len`'s message, so both apps say the
    /// same thing about the same path.
    func testAnOverlongSocketPathIsNamedWithItsLengthAndTheWayOut() {
        let path = "/" + String(repeating: "a", count: 103)
        XCTAssertEqual(
            ConnectionStatus.socketPathTooLong(path),
            "socket path is 104 bytes, over the 104-byte macOS sockaddr_un.sun_path cap: \(path); "
                + "set TARMAC_SOCKET to a shorter path, e.g. under /tmp"
        )
    }
}
