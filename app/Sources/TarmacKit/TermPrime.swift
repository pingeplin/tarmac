/// Which terminal on a board is prime once its terminals have changed.
public enum TermPrime {
    /// One terminal on a board: its id and whether its pty is live.
    public struct Term: Equatable, Sendable {
        public var termID: String
        public var isLive: Bool

        public init(termID: String, isLive: Bool) {
            self.termID = termID
            self.isLive = isLive
        }
    }

    /// The prime keeps prime while it is live; otherwise the first live terminal
    /// in card order takes over, and with none live nothing is prime. `terms` is
    /// the board's terminals in card order.
    public static func reassign(_ terms: [Term], prime: String?) -> String? {
        let live = terms.filter(\.isLive).map(\.termID)
        if let prime, live.contains(prime) { return prime }
        return live.first
    }
}
