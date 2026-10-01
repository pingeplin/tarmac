import CoreGraphics

/// A card's satellites as they stood when its header was pressed: the docs
/// attached to a terminal, which travel with it while it is dragged. The carry
/// belongs to that one card — no other card's move takes the satellites along.
public struct CardCarry<ID: Hashable> {
    public let owner: ID
    private let ownerOrigin: CGPoint
    private let satellites: [ID: CGPoint]

    /// `ownerOrigin` and each satellite's origin are world points at the press.
    public init(owner: ID, ownerOrigin: CGPoint, satellites: [ID: CGPoint]) {
        self.owner = owner
        self.ownerOrigin = ownerOrigin
        self.satellites = satellites
    }

    /// Where each satellite belongs with `card` at `origin`: moved by the
    /// owner's travel since the press, or nothing when `card` is not the owner.
    public func origins(moving card: ID, to origin: CGPoint) -> [ID: CGPoint] {
        guard card == owner else { return [:] }
        let dx = origin.x - ownerOrigin.x
        let dy = origin.y - ownerOrigin.y
        return satellites.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }
}
