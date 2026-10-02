import CoreGraphics

/// What a `doc_opened` does to the board it is routed to.
public enum DocLanding {
    public enum Decision: Equatable, Sendable {
        /// The doc is new to the board and lands a card.
        case land(fresh: Bool, attached: Bool)
        /// The doc already has a card. It is neither moved nor duplicated.
        case refresh(fresh: Bool)
    }

    /// Every open lands a card, whoever opened it. Only an agent's own
    /// `tarmac open` marks it fresh, and it follows its terminal when it
    /// names one.
    public static func decide(onBoard: Bool, via: String, termID: String?, wasFresh: Bool) -> Decision {
        onBoard
            ? .refresh(fresh: CardFresh.afterOpen(via: via, wasFresh: wasFresh))
            : .land(fresh: via == "cli", attached: termID != nil)
    }

    /// A re-open that names no terminal leaves the card with the owner it had.
    public static func owner(opened: String?, current: String?) -> String? {
        opened ?? current
    }

    /// The frame a new doc is placed beside: its owner terminal when that is on
    /// the board, else the board's prime terminal, else the boot frame.
    public static func anchor(owner: CGRect?, prime: CGRect?) -> CGRect {
        owner ?? prime ?? Placement.termFrame
    }
}
