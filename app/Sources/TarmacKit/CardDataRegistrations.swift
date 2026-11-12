/// Which data file each HTML card registered with the daemon (spec
/// 2611.0002). A `file_event` names a path and no board, so this is what
/// finds the cards to tell; and the daemon keeps a registration in memory
/// only, so this is what is sent again after a reconnect.
public struct CardDataRegistrations: Sendable {
    /// A card is a doc on a board.
    public struct Card: Hashable, Sendable {
        public let boardID: String
        public let path: String

        public init(boardID: String, path: String) {
            self.boardID = boardID
            self.path = path
        }
    }

    private var files: [Card: String] = [:]

    public init() {}

    /// `file` nil clears the card's registration.
    public mutating func set(_ file: String?, for card: Card) {
        files[card] = file
    }

    public func cards(reading file: String) -> [Card] {
        files.compactMap { $0.value == file ? $0.key : nil }
    }

    /// A `doc_data` for each card that reads a file.
    public var resent: [Message] {
        files.map { card, file in .docData(boardID: card.boardID, path: card.path, data: file) }
    }

    public mutating func forget(board boardID: String) {
        files = files.filter { $0.key.boardID != boardID }
    }
}
