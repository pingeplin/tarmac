/// What the terminals remember about the current daemon connection. A fresh
/// value replaces it when the connection drops.
struct DaemonSession {
    /// Boards whose `restore` has arrived on this connection. The daemon follows
    /// a board's first restore on a connection with its live terminals'
    /// scrollback rings, and a restore is what settles which terminals are
    /// alive — so no spawn goes out for a board before it.
    var restoredBoards: Set<String> = []
    /// The restart toast has been shown since the connection last dropped.
    var restartNotified = false
}
