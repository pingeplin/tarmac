import CoreGraphics

/// Pure doc→terminal provenance logic, kept view-independent in
/// TarmacKit so it is unit-tested.
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
}
