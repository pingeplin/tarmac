import CoreGraphics

public struct TerminalPadding: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    /// Tight on top because the sub-row remainder is added there: the seen top
    /// gap is this plus up to one row, which keeps it near the 16pt below.
    public static let card = TerminalPadding(top: 2, left: 10, bottom: 16, right: 10)
}

/// Where the cell grid sits inside a terminal view (top-down coordinates). The
/// grid is the whole cells the padded box holds, anchored to the bottom so the
/// leftover fraction of a row is above the first line, never below the last.
struct TerminalGridLayout: Equatable {
    let cols: Int
    let rows: Int
    let cell: CGSize
    let origin: CGPoint

    init?(bounds: CGSize, cell: CGSize, padding: TerminalPadding) {
        guard cell.width > 0, cell.height > 0 else { return nil }
        let cols = Self.wholeCells(bounds.width - padding.left - padding.right, cell.width)
        let rows = Self.wholeCells(bounds.height - padding.top - padding.bottom, cell.height)
        guard cols >= 1, rows >= 1 else { return nil }
        self.cols = cols
        self.rows = rows
        self.cell = cell
        origin = CGPoint(x: padding.left, y: bounds.height - padding.bottom - CGFloat(rows) * cell.height)
    }

    /// How many whole cells fit. A host that scales this view reads its bounds
    /// back through that scale, so an exact fit can arrive a few ulps short;
    /// that must not cost a cell, or zooming would resize the PTY.
    private static func wholeCells(_ extent: CGFloat, _ cell: CGFloat) -> Int {
        Int((extent / cell + 1e-6).rounded(.down))
    }

    var gridSize: CGSize {
        CGSize(width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height)
    }

    func rect(col: Int, row: Int, span: Int = 1) -> CGRect {
        CGRect(
            x: origin.x + CGFloat(col) * cell.width,
            y: origin.y + CGFloat(row) * cell.height,
            width: CGFloat(span) * cell.width,
            height: cell.height
        )
    }

    func rowRect(_ row: Int) -> CGRect {
        rect(col: 0, row: row, span: cols)
    }

    func surfacePoint(_ point: CGPoint) -> SurfacePoint {
        SurfacePoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    var surface: SurfaceGeometry {
        SurfaceGeometry(
            width: Int(gridSize.width.rounded()), height: Int(gridSize.height.rounded()),
            cellWidth: Int(cell.width.rounded()), cellHeight: Int(cell.height.rounded())
        )
    }
}
