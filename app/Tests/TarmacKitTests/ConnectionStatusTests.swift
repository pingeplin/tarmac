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
            ConnectionStatus.connectFailed("no daemon on the dev channel at /x/tarmacd.sock"),
            ConnectionStatus(connected: false, reason: "connect failed: no daemon on the dev channel at /x/tarmacd.sock")
        )
    }

    /// What the status bar prints for the link (`desktop/src/ui/StatusBar.tsx`).
    func testTheLabelIsAttachedOrTheReasonForNotBeing() {
        XCTAssertEqual(ConnectionStatus.connected.label, "attached")
        XCTAssertEqual(ConnectionStatus.connecting.label, "connecting…")
        XCTAssertEqual(ConnectionStatus.closed.label, "daemon connection closed")
        XCTAssertEqual(ConnectionStatus(connected: false, reason: nil).label, "detached")
    }

    /// Spec 2606.0003 S10: the path and the channel, as the CLI's "no tarmac
    /// daemon running" names them, so a dev app that finds no daemon says why.
    func testAMissingDaemonIsNamedByItsSocketAndChannel() {
        XCTAssertEqual(
            ConnectionStatus.noDaemon(at: "/repo/.dev/tarmacd.sock", channel: .dev),
            "no daemon on the dev channel at /repo/.dev/tarmacd.sock"
        )
        XCTAssertEqual(
            ConnectionStatus.noDaemon(at: "/x/tarmacd.sock", channel: .release),
            "no daemon on the release channel at /x/tarmacd.sock"
        )
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

    /// #384: `connected` is true from the socket's connect, before `hello_ok`.
    func testALinkWithAPendingHandshakeIsShownAsConnecting() {
        XCTAssertEqual(ConnectionStatus.connected.shown(handshook: false), .connecting)
        XCTAssertEqual(ConnectionStatus.connected.shown(handshook: true), .connected)
        XCTAssertEqual(ConnectionStatus.closed.shown(handshook: false), .closed)
        XCTAssertEqual(ConnectionStatus.restarting.shown(handshook: true), .restarting)
    }

    /// #384: the restart of a daemon of another version ends a link that
    /// never completed its handshake; the user lost nothing.
    func testOnlyALinkThatCompletedItsHandshakeIsLost() {
        XCTAssertTrue(ConnectionStatus.closed.endsLink(handshook: true))
        XCTAssertFalse(ConnectionStatus.closed.endsLink(handshook: false))
        XCTAssertFalse(ConnectionStatus.restarting.endsLink(handshook: false))
        XCTAssertFalse(ConnectionStatus.connected.endsLink(handshook: true))
    }
}
