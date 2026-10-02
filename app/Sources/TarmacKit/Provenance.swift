import CoreGraphics

/// Pure doc→terminal provenance logic (Phase 5b), kept view-independent in
/// TarmacKit so it is unit-tested.
public enum Provenance {
    /// Whether the provenance edge from the owner terminal to this doc should be
    /// shown. True only when the doc has an owner terminal and that terminal's
    /// card is present on the board. Never gated on `attached` — that is the
    /// gravity flag (does the card snap back beside its terminal), so dragging a
    /// doc away must not hide the edge.
    public static func edgeShown(ownerTermID: String?, ownerCardPresent: Bool) -> Bool {
        ownerTermID != nil && ownerCardPresent
    }

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
}
