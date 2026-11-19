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

    /// A card as the edge rule reads it: its frame, and the card that owns it.
    public protocol Linked {
        associatedtype OwnerID: Hashable
        var edgeFrame: CGRect { get }
        var ownerID: OwnerID? { get }
    }

    /// What the carry rule reads of a card. `owner` is the terminal card that
    /// made it; `attached` is its gravity flag.
    public struct Card<ID: Hashable & Sendable>: Sendable, Linked {
        public var frame: CGRect
        public var owner: ID?
        public var attached: Bool

        public init(frame: CGRect, owner: ID?, attached: Bool = true) {
            self.frame = frame
            self.owner = owner
            self.attached = attached
        }

        public var edgeFrame: CGRect { frame }
        public var ownerID: ID? { owner }
    }

    /// One edge for each card, of any kind, whose owner card is on the board.
    /// Never gated on `attached`: a doc dragged away keeps its edge (#39). It
    /// runs on every pan and zoom frame, so it reads the board's own cards and
    /// builds nothing but the edges.
    @inlinable
    public static func edges<C: Linked>(_ cards: [C.OwnerID: C]) -> [Segment] {
        cards.values.compactMap { card in
            guard let owner = card.ownerID, let ownerCard = cards[owner] else { return nil }
            return edge(owner: ownerCard.edgeFrame, card: card.edgeFrame)
        }
    }

    /// Whether a new card follows its owner. A doc does until it is moved by
    /// hand; a terminal card never does (2611.0016, D7): gravity that an app
    /// relaunch would drop is worse than none.
    public static func startsAttached(isDoc: Bool) -> Bool {
        isDoc
    }

    /// The cards a drag of `owner` carries: those it made that are attached.
    public static func carried<ID>(by owner: ID, among cards: [ID: Card<ID>]) -> [ID: CGRect] {
        cards.filter { $0.value.owner == owner && $0.value.attached }.mapValues(\.frame)
    }
}
