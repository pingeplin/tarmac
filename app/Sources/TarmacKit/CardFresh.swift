/// The "just landed" highlight on a doc card. It is raised only by an agent's
/// own `tarmac open` — every time, including a re-open of a card already on
/// the board — and never lowered by an open that came some other way.
public enum CardFresh {
    public static func afterOpen(via: String, wasFresh: Bool) -> Bool {
        via == "cli" || wasFresh
    }
}
