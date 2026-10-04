/// What the host tells an HTML card's document, as `card_shim.js` reads it.
/// Each is a state the shim applies as given; none asks a question.
public enum CardHostMessage: Equatable, Sendable {
    /// The root zoom the document is laid out at.
    case zoom(Double)
    /// Whether the card is culled. Re-sending the same value changes nothing.
    case cull(Bool)
    /// Where the root is scrolled to, in the document's own units: the scroll
    /// thumb is being dragged.
    case scrollTo(Double)

    /// The message as a JSON object, which is also a JavaScript literal.
    public var json: String {
        switch self {
        case .zoom(let z):
            return #"{"tarmac":"zoom","z":\#(z.javaScriptString)}"#
        case .cull(let culled):
            return #"{"tarmac":"cull","culled":\#(culled)}"#
        case .scrollTo(let y):
            return #"{"tarmac":"scrollTo","y":\#(y.javaScriptString)}"#
        }
    }
}
