import CoreGraphics

/// Where a `tarmac open` doc lands on the board. A fresh doc takes the first
/// free slot, with an 8 pt collision inset, in the rings around its owning
/// terminal, so several docs from one terminal surround it instead of landing
/// on top of each other. A persisted doc tile with no geometry falls back to a
/// deterministic two-column scatter.
///
/// World space is top-down/flipped (larger y is lower), like `BoardTransform`.
public enum Placement {
    /// The boot terminal frame and the doc size and gaps.
    public static let termFrame = CGRect(x: 80, y: 80, width: 470, height: 330)
    /// The viewport a board opens at when none was persisted: on the boot
    /// terminal, the one card such a board has.
    public static let openingViewport = BoardFly.destination(showing: termFrame)
    public static let docSize = CGSize(width: 392, height: 310)
    public static let gapX: CGFloat = 86
    public static let gapY: CGFloat = 40
    /// The rings around the owner `firstFreeSlot` tries before it stacks.
    public static let ringCount = 16
    /// A candidate slot must clear every existing card by this much.
    public static let collisionInset: CGFloat = 8
    public static let docColumns = 2

    /// Half-open overlap: rects that only share an edge do not intersect. An
    /// explicit formula rather than `CGRect.intersects`, which also reports two
    /// coincident zero-size rects as intersecting.
    public static func rectsIntersect(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    /// The world frame for a fresh card of `size` owned by `owner`: the first
    /// slot, ring by ring outward (`ringSlots`), that clears every `existing`
    /// card by `collisionInset`. When all `ringCount` rings are taken it stacks
    /// at the first slot — overlapping but still valid geometry.
    public static func firstFreeSlot(owner: CGRect, existing: [CGRect], size: CGSize = docSize) -> CGRect {
        let grown = existing.map { $0.insetBy(dx: -collisionInset, dy: -collisionInset) }
        return (0..<ringCount).lazy
            .flatMap { ringSlots(around: owner, ring: $0, size: size) }
            .first { slot in !grown.contains { rectsIntersect(slot, $0) } }
            ?? ringSlots(around: owner, ring: 0, size: size)[0]
    }

    /// The `ring`-th (0-based) ring of slots around `owner`, in placing order.
    /// First the sides, clockwise from the right: each side holds as many slots
    /// as start along the owner's edge, aligned to its top or left, and the k-th
    /// slot of every side comes before the (k+1)-th of any. Then the corners,
    /// clockwise from bottom-right. A corner can overlap a side slot of a big
    /// owner; the collision check then skips it. Ring n is ring 0 around
    /// `owner` grown by n pitches.
    static func ringSlots(around owner: CGRect, ring: Int, size: CGSize) -> [CGRect] {
        let pitchX = size.width + gapX
        let pitchY = size.height + gapY
        let o = owner.insetBy(dx: -CGFloat(ring) * pitchX, dy: -CGFloat(ring) * pitchY)
        let right = o.maxX + gapX, left = o.minX - pitchX
        let below = o.maxY + gapY, above = o.minY - pitchY
        let rows = Array(stride(from: o.minY, to: o.maxY, by: pitchY))
        let cols = Array(stride(from: o.minX, to: o.maxX, by: pitchX))
        var origins: [CGPoint] = []
        for k in 0..<max(rows.count, cols.count) {
            if k < rows.count { origins.append(CGPoint(x: right, y: rows[k])) }
            if k < cols.count { origins.append(CGPoint(x: cols[k], y: below)) }
            if k < rows.count { origins.append(CGPoint(x: left, y: rows[k])) }
            if k < cols.count { origins.append(CGPoint(x: cols[k], y: above)) }
        }
        origins += [
            CGPoint(x: right, y: below), CGPoint(x: left, y: below),
            CGPoint(x: left, y: above), CGPoint(x: right, y: above),
        ]
        return origins.map { CGRect(origin: $0, size: size) }
    }

    /// The frame of the `slot`-th (0-based) geometry-less doc: `docColumns`
    /// columns right of `owner`, filled top to bottom.
    public static func scatterFrame(slot: Int, owner: CGRect = termFrame) -> CGRect {
        let col = slot % docColumns
        let row = slot / docColumns
        return CGRect(
            origin: CGPoint(
                x: owner.maxX + gapX + CGFloat(col) * (docSize.width + gapX),
                y: owner.minY + CGFloat(row) * (docSize.height + gapY)
            ),
            size: docSize
        )
    }
}
