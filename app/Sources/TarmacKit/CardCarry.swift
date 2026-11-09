import CoreGraphics

/// A card's satellites as they stood when it was pressed: the docs attached to
/// a terminal, which travel with it while it is moved or resized. The carry
/// belongs to that one card — no other card's gesture takes the satellites
/// along.
public struct CardCarry<ID: Hashable> {
    public let owner: ID
    private let ownerFrame: CGRect
    private let satellites: [ID: CGRect]

    /// `ownerFrame` and each satellite's frame are world rects at the press.
    public init(owner: ID, ownerFrame: CGRect, satellites: [ID: CGRect]) {
        self.owner = owner
        self.ownerFrame = ownerFrame
        self.satellites = satellites
    }

    /// Where each satellite belongs with `card` at `frame`, or nothing when
    /// `card` is not the owner. On each axis a satellite follows the owner edge
    /// it faces, so its gap to that edge is the gap at the press. One between
    /// the owner's edges follows only when both edges moved alike — a move,
    /// never a resize.
    public func origins(moving card: ID, to frame: CGRect) -> [ID: CGPoint] {
        guard card == owner else { return [:] }
        return satellites.mapValues { s in
            CGPoint(
                x: s.minX + Self.shift(s.minX, s.maxX, from: (ownerFrame.minX, ownerFrame.maxX), to: (frame.minX, frame.maxX)),
                y: s.minY + Self.shift(s.minY, s.maxY, from: (ownerFrame.minY, ownerFrame.maxY), to: (frame.minY, frame.maxY))
            )
        }
    }

    private static func shift(
        _ lo: CGFloat, _ hi: CGFloat, from: (lo: CGFloat, hi: CGFloat), to: (lo: CGFloat, hi: CGFloat)
    ) -> CGFloat {
        let low = to.lo - from.lo
        let high = to.hi - from.hi
        if lo >= from.hi { return high }
        if hi <= from.lo { return low }
        return low == high ? low : 0
    }
}
