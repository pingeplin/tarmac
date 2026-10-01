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
}
