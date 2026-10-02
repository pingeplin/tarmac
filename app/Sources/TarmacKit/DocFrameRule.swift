/// The content rule a markdown doc's web view loads under: nothing in a child
/// frame loads from the `img` host.
///
/// A doc may frame a web page, and that page can name any local image. An
/// `<img>` of one tells it whether the file exists and how large the picture
/// is. The scheme handler cannot refuse it: the request carries nothing the
/// doc's own image load does not, and for an image the doc already shows
/// WebKit answers from its cache without asking. So WebKit is given the rule
/// instead, and the doc's own images, which load in the top frame, are not
/// touched by it.
public enum DocFrameRule {
    public static let identifier = "tarmac-doc-frames"

    /// The rule list as `WKContentRuleListStore` compiles it.
    public static let json = """
    [{"trigger": {"url-filter": "^\(ImageProtocol.uriPrefix)", "load-context": ["child-frame"]}, "action": {"type": "block"}}]
    """
}
