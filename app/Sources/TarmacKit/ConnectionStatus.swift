/// The daemon link as the app shows it: connected or not, and why not. The
/// values are the ones `desktop/src-tauri/src/bridge.rs` emits, text included —
/// the status bar prints `reason` as it stands.
public struct ConnectionStatus: Equatable, Sendable {
    public var connected: Bool
    public var reason: String?

    public init(connected: Bool, reason: String?) {
        self.connected = connected
        self.reason = reason
    }

    /// What the app shows before the first connect attempt has reported.
    public static let connecting = ConnectionStatus(connected: false, reason: "connecting…")
    public static let connected = ConnectionStatus(connected: true, reason: nil)
    public static let closed = ConnectionStatus(connected: false, reason: "daemon connection closed")
    public static let restarting = ConnectionStatus(connected: false, reason: "version mismatch / restarting")
    public static let gaveUp = ConnectionStatus(connected: false, reason: "could not reconnect to tarmacd")

    public static func connectFailed(_ detail: String) -> ConnectionStatus {
        ConnectionStatus(connected: false, reason: "connect failed: \(detail)")
    }

    /// What the status bar prints.
    public var label: String {
        connected ? "attached" : reason ?? "detached"
    }

    // MARK: - Connect-failure details

    public static func noDaemon(at socketPath: String) -> String {
        "no daemon at \(socketPath)"
    }

    /// `tarmac_protocol::check_socket_path_len`'s message.
    public static func socketPathTooLong(_ socketPath: String) -> String {
        "socket path is \(socketPath.utf8.count) bytes, over the 104-byte macOS sockaddr_un.sun_path cap: "
            + "\(socketPath); set TARMAC_SOCKET to a shorter path, e.g. under /tmp"
    }
}
