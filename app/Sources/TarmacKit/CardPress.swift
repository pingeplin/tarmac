/// Which presses on a card select and raise it. Most do; a press on something
/// that acts by itself is that thing's alone.
public enum CardPress {
    public enum Place: Equatable, Sendable {
        /// A control that acts by itself: `✕`, `↻`, the console badge, the
        /// `resume` chip, a resume panel's button.
        case headerControl
        /// A link in a doc card's body. Following it does not pick the card up.
        case link
        case elsewhere
    }

    public static func selects(_ place: Place) -> Bool {
        place == .elsewhere
    }

    /// A press on the board outside every card: the bare board clears the
    /// selection, while a control that lies outside its card, a resume
    /// panel's button (2611.0015 D9), acts by itself and leaves it.
    public static func clearsSelection(_ place: Place) -> Bool {
        place == .elsewhere
    }
}
