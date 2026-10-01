/// Remembers each card's last visibility so a cull pass, which runs on every
/// pan and zoom frame, touches a card and tells its listeners only when the
/// card's state actually changed.
public struct CullLedger<ID: Hashable> {
    private var visibility: [ID: Bool] = [:]

    public init() {}

    /// Records `visible` for `id` and reports whether that is news: the first
    /// time a card is seen, or a flip from what was recorded last.
    public mutating func record(_ id: ID, visible: Bool) -> Bool {
        visibility.updateValue(visible, forKey: id) != visible
    }

    /// Drops a removed card, so one re-added under the same id reports afresh.
    public mutating func forget(_ id: ID) {
        visibility[id] = nil
    }
}
