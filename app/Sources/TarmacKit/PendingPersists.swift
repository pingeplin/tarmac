/// Which boards owe the daemon a layout snapshot. Each board waits on its own:
/// a change restarts that board's wait and leaves every other board's alone, so
/// a burst of changes collapses to one snapshot per board.
///
/// Owns no clock: `schedule` hands out a token for the caller's timer, and
/// `fire` says whether that timer is still the board's latest.
public struct PendingPersists {
    /// How long a board must stay unchanged before its snapshot is sent.
    public static let debounceMs = 200

    private var tokens: [String: UInt64] = [:]
    private var lastToken: UInt64 = 0

    public init() {}

    public func isPending(_ boardID: String) -> Bool {
        tokens[boardID] != nil
    }

    /// The board changed. Returns the token its timer must present to `fire`.
    public mutating func schedule(_ boardID: String) -> UInt64 {
        lastToken += 1
        tokens[boardID] = lastToken
        return lastToken
    }

    /// A timer ran out. True when the snapshot is due — false for a timer a
    /// later change superseded, or one whose board was flushed meanwhile.
    public mutating func fire(_ boardID: String, token: UInt64) -> Bool {
        guard tokens[boardID] == token else { return false }
        tokens[boardID] = nil
        return true
    }

    /// A board is being left, or the app is going to the background or
    /// quitting: every board that owes a snapshot, to be sent now.
    public mutating func flushAll() -> [String] {
        defer { tokens = [:] }
        return tokens.keys.sorted()
    }
}
