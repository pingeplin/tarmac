import CoreGraphics

/// Pure provenance logic — a card and the terminal that made it — kept
/// view-independent in TarmacKit so it is unit-tested.
public enum Provenance {
    public struct Segment: Equatable, Sendable {
        public var from: CGPoint
        public var to: CGPoint

        public init(from: CGPoint, to: CGPoint) {
            self.from = from
            self.to = to
        }
    }

    /// The edge of a doc: a straight segment from its owner card's centre to
    /// its own. Drawn beneath the cards, only the gap between them shows.
    public static func edge(owner: CGRect, doc: CGRect) -> Segment {
        Segment(from: CGPoint(x: owner.midX, y: owner.midY), to: CGPoint(x: doc.midX, y: doc.midY))
    }

    public enum Kind: Sendable {
        case doc
        case term
    }

    /// What the rules read of a card. `owner` is the terminal card that made
    /// it; `attached` is a doc's gravity flag.
    public struct Card<ID: Hashable & Sendable>: Sendable {
        public var frame: CGRect
        public var owner: ID?
        public var kind: Kind
        public var attached: Bool

        public init(frame: CGRect, owner: ID?, kind: Kind, attached: Bool = true) {
            self.frame = frame
            self.owner = owner
            self.kind = kind
            self.attached = attached
        }
    }

    /// One edge for each card, of any kind, whose owner card is on the board.
    /// Never gated on `attached`: a doc dragged away keeps its edge (#39).
    public static func edges<ID>(_ cards: [ID: Card<ID>]) -> [Segment] {
        cards.values.compactMap { card in
            guard let owner = card.owner, let ownerCard = cards[owner] else { return nil }
            return edge(owner: ownerCard.frame, doc: card.frame)
        }
    }

    /// The cards a drag of `owner` carries: its attached docs. A terminal
    /// card it made is not attached (2611.0016, D7): gravity that an app
    /// relaunch would drop is worse than none.
    public static func carried<ID>(by owner: ID, among cards: [ID: Card<ID>]) -> [ID: CGRect] {
        cards.filter { $0.value.kind == .doc && $0.value.owner == owner && $0.value.attached }.mapValues(\.frame)
    }
}
