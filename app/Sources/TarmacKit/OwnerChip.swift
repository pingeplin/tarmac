/// The doc-card owner-chip rule: the chip shows "← <owner terminal label>"
/// whenever the owner terminal still exists with a non-empty label. Provenance
/// chrome is independent of the card's gravity (`attached`) flag.
public enum OwnerChip {
    /// The label without the "← " prefix, or nil when the chip is hidden.
    /// `labelOf` returns a term's current display label, or nil when that term is
    /// gone (exited / not on this board).
    public static func name(ownerTermID: String?, labelOf: (String) -> String?) -> String? {
        guard let ownerTermID, !ownerTermID.isEmpty,
              let label = labelOf(ownerTermID), !label.isEmpty
        else { return nil }
        return label
    }
}
