/// What the host tells an HTML card's document, as `card_shim.js` reads it.
/// Each is a state or a delta the shim applies as given; none asks a question.
public enum CardHostMessage: Equatable, Sendable {
    /// The root zoom the document is laid out at.
    case zoom(Double)
    /// Whether the card is culled. Re-sending the same value changes nothing.
    case cull(Bool)
    /// A wheel step over the shield, in the document's own pixels.
    case scroll(dx: Int, dy: Int)

    /// The message as a JSON object, which is also a JavaScript literal.
    public var json: String {
        switch self {
        case .zoom(let z):
            return #"{"tarmac":"zoom","z":\#(z.javaScriptString)}"#
        case .cull(let culled):
            return #"{"tarmac":"cull","culled":\#(culled)}"#
        case .scroll(let dx, let dy):
            return #"{"tarmac":"scroll","dx":\#(dx),"dy":\#(dy)}"#
        }
    }
}
