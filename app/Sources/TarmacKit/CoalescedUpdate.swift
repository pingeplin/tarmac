/// Many changes, one update. A view told of every change asks whether to
/// schedule a refresh; only the first change since the last refresh ran says
/// yes, so a burst costs one refresh however long it is.
public struct CoalescedUpdate: Equatable, Sendable {
    private var scheduled = false

    public init() {}

    /// Notes a change. True when the caller is to schedule the update that
    /// will cover it; false when one is already on its way.
    public mutating func changed() -> Bool {
        defer { scheduled = true }
        return !scheduled
    }

    /// The scheduled update is running: a later change needs another.
    public mutating func ran() {
        scheduled = false
    }
}
