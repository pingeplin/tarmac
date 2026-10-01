/// Stacking is one order across every kind of card on a board.
public enum ZOrder {
    /// The highest `z` on the board, never below zero.
    public static func top(_ zs: some Sequence<Int>) -> Int {
        zs.reduce(0, max)
    }

    /// The `z` a pressed or newly placed card takes: above every card on the
    /// board, itself included — so a card already on top still moves up.
    public static func raised(above zs: some Sequence<Int>) -> Int {
        top(zs) + 1
    }

    /// A card's place in the stack, back to front: by `z`, and among cards of
    /// equal `z` by the order they were added to the board. Restored tiles
    /// without a `z` all sit at zero, so the tie has to be settled the same way
    /// on every restack.
    public struct Place: Comparable, Sendable {
        public let z: Int
        public let added: Int

        public init(z: Int, added: Int) {
            self.z = z
            self.added = added
        }

        public static func < (a: Place, b: Place) -> Bool {
            (a.z, a.added) < (b.z, b.added)
        }
    }
}
