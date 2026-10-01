/// The one HTML card whose shield is down, app-wide (spec 2607.0004).
public struct CardBorrow<ID: Equatable> {
    public private(set) var id: ID?

    public init() {}

    public mutating func borrow(_ id: ID) {
        self.id = id
    }

    /// Returns whether a card was borrowed.
    public mutating func release() -> Bool {
        defer { id = nil }
        return id != nil
    }

    public mutating func closed(_ id: ID) {
        if self.id == id { self.id = nil }
    }

    /// Whether `id` is drawn borrowed. A board switch leaves the borrow in
    /// place; a card on a board that is not on screen is only drawn shielded.
    public func shows(_ id: ID, boardVisible: Bool) -> Bool {
        boardVisible && self.id == id
    }
}
