/// The board's cull report as an HTML card's scheduler gate reads it (spec
/// 2609.0002).
public enum CardCull {
    /// The one place the polarity is inverted, so it cannot be inverted twice
    /// or not at all.
    public static func isCulled(visible: Bool) -> Bool {
        !visible
    }
}
