/// A card that can report and drop its fresh-doc highlight. TarmacKit has no
/// card model of its own; the app's card type adopts this narrow view of it.
public protocol ClearableFreshDoc {
    var isFreshDoc: Bool { get }
    mutating func clearFresh()
}

/// Issue #50: ESC's "dismiss fresh doc" rung must only clear the highlight,
/// never remove the card — removal stays reserved for the ✕ / ⌘W path.
public enum ClearFreshDoc {
    /// Clears `fresh` on every doc card that has it set. Every other card is
    /// returned untouched, and no card is ever added, removed or reordered.
    public static func apply<Card: ClearableFreshDoc>(to cards: [Card]) -> [Card] {
        cards.map { card in
            guard card.isFreshDoc else { return card }
            var cleared = card
            cleared.clearFresh()
            return cleared
        }
    }
}
