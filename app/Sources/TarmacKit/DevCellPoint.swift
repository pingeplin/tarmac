import CoreGraphics

/// Where `tarmac dev key <card> contextmenu` right-clicks (spec 2609.0015, issue
/// #166): the last cell of the viewport that has a character in it, so the
/// terminal's right-click selects a word. A click on blank space selects
/// nothing, which would silently turn the Range scenario into a second copy of
/// the caret one — hence a refusal rather than a best-effort point.
public enum DevCellPoint {
    public struct Cell: Equatable, Sendable {
        public var col: Int
        public var row: Int

        public init(col: Int, row: Int) {
            self.col = col
            self.row = row
        }
    }

    /// `rows` is the VIEWPORT, top-first, one string per grid row — not the
    /// scrollback. Nil when no row holds anything but blanks.
    ///
    /// The column is counted in graphemes: each occupies at least one cell, so
    /// the count never runs past the written cells. A wide character makes it
    /// land short of the last one, still on text.
    public static func lastWrittenCell(in rows: [String]) -> Cell? {
        for (row, text) in rows.enumerated().reversed() {
            guard let last = text.lastIndex(where: { !$0.isWhitespace }) else { continue }
            return Cell(col: text.distance(from: text.startIndex, to: last), row: row)
        }
        return nil
    }

    /// The cell's centre, in whatever space `grid` — the rectangle the `cols` ×
    /// `rows` cells fill — is given in. Row 0 is at `grid.minY`.
    public static func centre(of cell: Cell, in grid: CGRect, cols: Int, rows: Int) -> CGPoint {
        CGPoint(
            x: grid.minX + (CGFloat(cell.col) + 0.5) * (grid.width / CGFloat(cols)),
            y: grid.minY + (CGFloat(cell.row) + 0.5) * (grid.height / CGFloat(rows))
        )
    }

    public static func emptyBuffer(card: String) -> DevError {
        DevError(
            .emptyBuffer,
            "the terminal's viewport holds no text to right-click; a blank cell yields no selection",
            extra: ["card": .string(card)]
        )
    }
}
