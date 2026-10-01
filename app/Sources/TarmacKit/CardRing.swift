/// The 3-wide ring outside a card's border: teal on a doc an agent just
/// opened, amber on the HTML card that holds the keyboard.
public enum CardRing: Equatable, Sendable {
    case fresh, borrowed

    /// A card wears one ring at a time, and the borrow's outranks the fresh one.
    public static func of(fresh: Bool, borrowed: Bool) -> CardRing? {
        borrowed ? .borrowed : fresh ? .fresh : nil
    }
}
