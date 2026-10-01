/// Issue #77: which terminal a fresh ⌘T terminal inherits its cwd from. The
/// daemon resolves the actual live directory at spawn time; this only decides
/// WHICH terminal to ask, so the app stays a thin pass-through.
public enum CwdInherit {
    /// A terminal card, reduced to what a prime-terminal decision needs.
    public struct Candidate: Equatable, Sendable {
        public var termID: String
        public var prime: Bool
        public var live: Bool
        public var dead: Bool

        public init(termID: String, prime: Bool, live: Bool, dead: Bool) {
            self.termID = termID
            self.prime = prime
            self.live = live
            self.dead = dead
        }
    }

    /// The board's live prime terminal — the one keyboard focus goes home to — or
    /// nil when there is none (empty board, or a prime that isn't live).
    public static func primeTermID(in cards: [Candidate]) -> String? {
        cards.first { $0.prime && $0.live && !$0.dead }?.termID
    }

    /// The term whose live cwd a new ⌘T terminal inherits, or nil when there is no
    /// eligible source — ⌘T then falls back to the daemon's default cwd.
    public static func source(in cards: [Candidate]) -> String? {
        primeTermID(in: cards)
    }
}
