/// Which presses on a card select and raise it. Most do; a press on something
/// that acts by itself is that thing's alone.
public enum CardPress {
    public enum Place: Equatable, Sendable {
        /// A header control: `✕`, `↻`, the console badge.
        case headerControl
        /// A link in a doc card's body. Following it does not pick the card up.
        case link
        case elsewhere
    }

    public static func selects(_ place: Place) -> Bool {
        place == .elsewhere
    }
}
