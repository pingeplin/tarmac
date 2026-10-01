/// Which card a board ends up with selected. Only a board that is on screen
/// holds a selection, so a card set up on a background board never arrives
/// already selected; and only a card the board has can be selected.
public enum CardSelection {
    public static func resolve<ID>(_ requested: ID?, onScreen: Bool, isOnBoard: (ID) -> Bool) -> ID? {
        guard onScreen, let requested, isOnBoard(requested) else { return nil }
        return requested
    }
}
