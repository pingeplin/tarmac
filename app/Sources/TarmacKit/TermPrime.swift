/// Which terminal on a board is prime once its terminals have changed.
public enum TermPrime {
    /// The prime keeps prime while it is live; otherwise the first live terminal
    /// in card order takes over, and with none live nothing is prime. `terms` is
    /// the board's terminals in card order.
    public static func reassign(_ terms: [TermCycle.Term], prime: String?) -> String? {
        let live = TermCycle.order(terms)
        if let prime, live.contains(prime) { return prime }
        return live.first
    }
}
