/// The content rule an HTML card's web view loads under: nothing loads from
/// the network, in any frame.
///
/// A card's content policy is a header of its document and speaks for what
/// that document asks for. This is the same refusal one level down, in
/// WebKit's own loader, for every load of the web view. What a card is
/// served — the card scheme, `data:` and `blob:` — matches neither filter.
public enum CardNetworkRule {
    public static let identifier = "tarmac-card-network"

    /// The rule list as `WKContentRuleListStore` compiles it.
    public static let json = """
    [{"trigger": {"url-filter": "^https?:"}, "action": {"type": "block"}},
     {"trigger": {"url-filter": "^wss?:"}, "action": {"type": "block"}}]
    """
}
