/// Numbers the loads of one page or document. What a load causes arrives
/// later and names its number; by then the page can have been loaded again,
/// and only the word for the current load is obeyed.
public struct LoadCount: Equatable, Sendable {
    private var current = 0

    public init() {}

    /// The number of a new load, which is then the current one.
    public mutating func next() -> Int {
        current += 1
        return current
    }

    /// False for every number before the first load.
    public func isCurrent(_ load: Int) -> Bool {
        current > 0 && load == current
    }
}
