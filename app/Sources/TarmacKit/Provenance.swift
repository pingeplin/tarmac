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

    /// The edge of a card with an owner: a straight segment from its owner
    /// card's centre to its own. Drawn beneath the cards, only the gap
    /// between them shows.
    public static func edge(owner: CGRect, card: CGRect) -> Segment {
        Segment(from: CGPoint(x: owner.midX, y: owner.midY), to: CGPoint(x: card.midX, y: card.midY))
    }

    /// What the carry rule reads of a card. `owner` is the terminal card that
    /// made it; `attached` is its gravity flag.
    public struct Card<ID: Hashable & Sendable>: Sendable {
        public var frame: CGRect
        public var owner: ID?
        public var attached: Bool

        public init(frame: CGRect, owner: ID?, attached: Bool = true) {
            self.frame = frame
            self.owner = owner
            self.attached = attached
        }
    }

    /// One edge for each card, of any kind, whose owner card is on the board:
    /// `ownerFrame` gives the owner's frame, nil when it is gone. Never gated
    /// on `attached`: a doc dragged away keeps its edge (#39). It runs on
    /// every pan and zoom frame, so it takes the cards as they are.
    @inlinable
    public static func edges<Cards: Sequence>(
        _ cards: Cards, frame: (Cards.Element) -> CGRect, ownerFrame: (Cards.Element) -> CGRect?
    ) -> [Segment] {
        cards.compactMap { card in ownerFrame(card).map { edge(owner: $0, card: frame(card)) } }
    }

    /// The cards a drag of `owner` carries: those it made that are attached.
    public static func carried<ID>(by owner: ID, among cards: [ID: Card<ID>]) -> [ID: CGRect] {
        cards.filter { $0.value.owner == owner && $0.value.attached }.mapValues(\.frame)
    }
}
