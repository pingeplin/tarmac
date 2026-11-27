/// The card a QA-driver verb names by its wire id. An id is its bytes, as a
/// doc path is (spec 2611.0034): Swift's `String ==` would take a card whose
/// name is the other Unicode form of the one asked for.
public enum DevCardLookup {
    public static func card<Card>(
        _ id: String, in cards: some Sequence<Card>, wireID: (Card) -> String
    ) -> Card? {
        cards.first { DocPath(wireID($0)) == DocPath(id) }
    }
}
