/// A jump from an inbox row to its card (spec 2611.0013): one board switch at
/// most, then one flight. The card it lands on is `Inbox.target(termID:)`.
public enum InboxJump {
    public enum Landing: Equatable, Sendable {
        /// A live card: it becomes prime and takes the keyboard.
        case prime
        /// A dead card: selected; the keyboard stays with the board.
        case select
        /// No card: the item goes, and nothing flies.
        case drop
    }

    /// The board a jump switches to first, or nil when the item is on the
    /// active board.
    public static func switchTarget(_ item: Inbox.Item, activeBoardID: String) -> String? {
        item.boardID == activeBoardID ? nil : item.boardID
    }

    public static func land(cardExists: Bool, cardDead: Bool) -> Landing {
        guard cardExists else { return .drop }
        return cardDead ? .select : .prime
    }
}
