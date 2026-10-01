import CoreGraphics

/// Where `tarmac dev key <card> contextmenu` right-clicks (spec 2609.0015, issue
/// #166): the last cell of the viewport that has a character in it, so the
/// terminal's right-click selects a word. A click on blank space selects
/// nothing, which would silently turn the Range scenario into a second copy of
/// the caret one — hence a refusal rather than a best-effort point, and a
/// target read off the grid's cells rather than guessed from a row's text.
public enum DevCellPoint {
    public struct Cell: Equatable, Sendable {
        public var col: Int
        public var row: Int

        public init(col: Int, row: Int) {
            self.col = col
            self.row = row
        }
    }

    /// `rows` is the VIEWPORT — not the scrollback — top-first, and each row is
    /// the grid's own cells, left to right, by their text: empty for an unwritten
    /// cell and for the spacer after a wide character. Nil when every cell is
    /// blank.
    ///
    /// Cells rather than a string, because a column is a grid position: a wide
    /// character holds two of them, and a count of characters lands one short
    /// per wide character — on the blank beside the last word, where a
    /// right-click selects nothing and the verb would still answer ok.
    ///
    /// Blank is empty or Unicode White_Space. The Tauri driver trims with JS
    /// `\s`, which also counts U+FEFF and does not count U+0085; no terminal
    /// writes either into a cell.
    public static func lastWrittenCell(in rows: [[String]]) -> Cell? {
        for (row, cells) in rows.enumerated().reversed() {
            guard let col = cells.lastIndex(where: { !$0.allSatisfy(\.isWhitespace) }) else { continue }
            return Cell(col: col, row: row)
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
