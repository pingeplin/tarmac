/// Cycle-the-prime-terminal logic: the order and the wrapping step. The HUD's
/// time-based reveal/fade and the key wiring stay in the view layer.
public enum TermCycle {
    /// One terminal eligible for the cycle: stable id + whether its pty is live.
    public struct Term: Equatable, Sendable {
        public var termID: String
        public var isLive: Bool

        public init(termID: String, isLive: Bool) {
            self.termID = termID
            self.isLive = isLive
        }
    }

    public enum Direction: Equatable, Sendable {
        case next, prev
    }

    /// Live terminals in stable input (spawn) order; dead ones are dropped.
    public static func order(_ terms: [Term]) -> [String] {
        terms.filter(\.isLive).map(\.termID)
    }

    /// The term to focus when cycling `direction` from `current` over `order`,
    /// wrapping at both ends. When `current` is nil or not in `order` (focus was on
    /// a doc, or the current term just died), `.next` lands on the first and `.prev`
    /// on the last. Nil only when `order` is empty.
    public static func step(order: [String], from current: String?, _ direction: Direction) -> String? {
        guard let first = order.first, let last = order.last else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return direction == .next ? first : last
        }
        switch direction {
        case .next: return order[(index + 1) % order.count]
        case .prev: return order[(index - 1 + order.count) % order.count]
        }
    }

    public static func cycle(_ terms: [Term], from current: String?, _ direction: Direction) -> String? {
        step(order: order(terms), from: current, direction)
    }
}
