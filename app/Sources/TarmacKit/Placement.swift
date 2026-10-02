import CoreGraphics

/// Where a `tarmac open` doc lands on the board. A fresh doc is placed beside its
/// owning terminal by a first-free-slot grid search with an 8 pt collision inset,
/// so several docs from one terminal stack neatly instead of landing on top of
/// each other. A persisted doc tile with no geometry (the M1 migration path)
/// falls back to a deterministic two-column scatter.
///
/// World space is top-down/flipped (larger y is lower), like `BoardTransform`.
public enum Placement {
    /// The boot terminal frame and the doc size and gaps.
    public static let termFrame = CGRect(x: 80, y: 80, width: 470, height: 330)
    /// The viewport a board opens at when none was persisted: on the boot
    /// terminal, the one card such a board has.
    public static let openingViewport = BoardFly.destination(showing: termFrame)
    public static let docWidth: CGFloat = 392
    public static let docHeight: CGFloat = 310
    public static let gapX: CGFloat = 86
    public static let gapY: CGFloat = 40
    /// The ⌘T terminal cascade nudge, consumed by `BoardWayfinding.cascadeOrigin`.
    public static let cascadeDX: CGFloat = 43
    public static let cascadeDY: CGFloat = 40
    public static let scanRows = 64
    public static let scanCols = 64
    /// A candidate slot must clear every existing card by this much.
    public static let collisionInset: CGFloat = 8
    public static let docColumns = 2

    /// Half-open overlap: rects that only share an edge do not intersect. An
    /// explicit formula rather than `CGRect.intersects`, which also reports two
    /// coincident zero-size rects as intersecting.
    public static func rectsIntersect(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    /// The world frame for a fresh doc card owned by `owner`: the first
    /// `docWidth × docHeight` slot, scanned row-major from the anchor (owner's
    /// right edge + `gapX`, owner's top), that clears every `existing` card by
    /// `collisionInset`. A fully occupied grid stacks at the anchor — overlapping
    /// but still valid geometry.
    public static func firstFreeSlot(owner: CGRect, existing: [CGRect]) -> CGRect {
        let startX = owner.maxX + gapX
        let startY = owner.minY
        let grown = existing.map { $0.insetBy(dx: -collisionInset, dy: -collisionInset) }
        for row in 0..<scanRows {
            for col in 0..<scanCols {
                let candidate = CGRect(
                    x: startX + CGFloat(col) * (docWidth + gapX),
                    y: startY + CGFloat(row) * (docHeight + gapY),
                    width: docWidth,
                    height: docHeight
                )
                if !grown.contains(where: { rectsIntersect(candidate, $0) }) { return candidate }
            }
        }
        return CGRect(x: startX, y: startY, width: docWidth, height: docHeight)
    }

    /// The frame of the `slot`-th (0-based) geometry-less doc: `docColumns`
    /// columns right of `owner`, filled top to bottom.
    public static func scatterFrame(slot: Int, owner: CGRect = termFrame) -> CGRect {
        let col = slot % docColumns
        let row = slot / docColumns
        return CGRect(
            x: owner.maxX + gapX + CGFloat(col) * (docWidth + gapX),
            y: owner.minY + CGFloat(row) * (docHeight + gapY),
            width: docWidth,
            height: docHeight
        )
    }
}
