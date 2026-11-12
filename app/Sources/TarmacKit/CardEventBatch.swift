/// The pushed texts an HTML card took since its last flush (spec 2611.0003),
/// which go to the document in one script call. It has no bound of its own.
public struct CardEventBatch: Equatable, Sendable {
    private var texts: [String] = []

    public init() {}

    /// Whether a flush is to be scheduled: the batch was empty.
    @discardableResult
    public mutating func add(_ text: String) -> Bool {
        texts.append(text)
        return texts.count == 1
    }

    public mutating func take() -> [String] {
        defer { texts = [] }
        return texts
    }

    /// The document is asked for again: what it was to get is not the next
    /// one's. A flush already scheduled then takes nothing.
    public mutating func drop() {
        texts = []
    }
}
