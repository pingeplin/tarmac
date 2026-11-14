/// A jump from an inbox row to its card (spec 2611.0013): one board switch at
/// most, then one flight. The card it lands on is `Inbox.target(termID:)`.
public enum InboxJump {
    public enum Plan: Equatable, Sendable {
        case fly(termID: String)
        case switchThenFly(boardID: String, termID: String)
    }

    public enum Landing: Equatable, Sendable {
        /// A live card: it becomes prime and takes the keyboard.
        case prime
        /// A dead card: selected; the keyboard stays with the board.
        case select
        /// No card: the item goes, and nothing flies.
        case drop
    }

    public static func plan(_ item: Inbox.Item, activeBoardID: String) -> Plan {
        item.boardID == activeBoardID
            ? .fly(termID: item.termID) : .switchThenFly(boardID: item.boardID, termID: item.termID)
    }

    public static func land(cardExists: Bool, cardDead: Bool) -> Landing {
        guard cardExists else { return .drop }
        return cardDead ? .select : .prime
    }
}
