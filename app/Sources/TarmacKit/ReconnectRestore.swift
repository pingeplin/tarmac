/// What a `restore` means for a board that is already built: the daemon's
/// `live_terms` is reconciled against the terminals the board believes are
/// running. Nothing is respawned.
public enum ReconnectRestore {
    public enum Pty: Equatable, Sendable {
        /// The card exists but its spawn has not been sent.
        case unspawned
        case live
        case dead
    }

    public struct Term: Equatable, Sendable {
        public var termID: String
        public var pty: Pty

        public init(termID: String, pty: Pty) {
            self.termID = termID
            self.pty = pty
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// Terminals to hold open as dead cards, in card order.
        public var lost: [String]
        /// Every PTY on every board is gone.
        public var daemonRestarted: Bool
        /// Surviving terminals whose history the daemon is about to send again.
        public var replayed: [String]

        public init(lost: [String], daemonRestarted: Bool, replayed: [String]) {
            self.lost = lost
            self.daemonRestarted = daemonRestarted
            self.replayed = replayed
        }
    }

    public static let restartToastTitle = "daemon restarted — terminals lost"
    public static let restartToastBody = "open new terminals with ⌘T"

    /// `terms` is the board's terminals in card order. A live terminal missing
    /// from `liveTerms` is lost. An empty `liveTerms` for a board that had a
    /// live terminal is a full daemon restart — a socket blip the daemon
    /// survived lists the survivors.
    ///
    /// `replayFollows` is true for the board's first restore on a connection,
    /// which the daemon follows with each live terminal's whole scrollback ring.
    /// A card that already shows that history must replace it, not append to it.
    public static func reconcile(_ terms: [Term], liveTerms: Set<String>, replayFollows: Bool) -> Outcome {
        let live = terms.filter { $0.pty == .live }.map(\.termID)
        return Outcome(
            lost: live.filter { !liveTerms.contains($0) },
            daemonRestarted: liveTerms.isEmpty && !live.isEmpty,
            replayed: replayFollows ? live.filter(liveTerms.contains) : []
        )
    }

    /// A daemon restart kills every board's PTYs, but only the active board is
    /// sent a restore: the terminals to hold open as dead on any other board.
    public static func lostToRestart(_ terms: [Term]) -> [String] {
        terms.filter { $0.pty == .live }.map(\.termID)
    }
}
