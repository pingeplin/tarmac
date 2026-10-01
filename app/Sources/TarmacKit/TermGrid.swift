import CoreGraphics

/// The terminal grid a card's box can actually hold (spec 2609.0011, #130).
///
/// Everything here is arithmetic on numbers the caller measured. The rows must be
/// counted against the box the text is painted in — the content box, the card's
/// box less its padding — not the padding box: counting against the taller one
/// leaves a surplus row that falls out of the card. Reconciling a board zoom
/// with the grid is not this module's job.
public enum TermGrid {
    /// A measured card box, in points.
    public struct Box: Equatable, Sendable {
        /// The padding box the content sits in, padding included.
        public var boxHeight: CGFloat
        public var boxWidth: CGFloat
        /// Padding inside that box the grid must not use.
        public var paddingVertical: CGFloat
        public var paddingHorizontal: CGFloat
        /// Width the scrollbar reserves; 0 when none is shown.
        public var scrollbarWidth: CGFloat
        /// Renderer cell metrics.
        public var cellWidth: CGFloat
        public var cellHeight: CGFloat

        public init(
            boxHeight: CGFloat,
            boxWidth: CGFloat,
            paddingVertical: CGFloat,
            paddingHorizontal: CGFloat,
            scrollbarWidth: CGFloat,
            cellWidth: CGFloat,
            cellHeight: CGFloat
        ) {
            self.boxHeight = boxHeight
            self.boxWidth = boxWidth
            self.paddingVertical = paddingVertical
            self.paddingHorizontal = paddingHorizontal
            self.scrollbarWidth = scrollbarWidth
            self.cellWidth = cellWidth
            self.cellHeight = cellHeight
        }
    }

    public struct Grid: Equatable, Sendable {
        public var cols: Int
        public var rows: Int

        public init(cols: Int, rows: Int) {
            self.cols = cols
            self.rows = rows
        }
    }

    /// The smallest grid ever proposed, so a collapsed card never asks its PTY for a
    /// zero-sized window.
    public static let minCols = 2
    public static let minRows = 1

    /// The largest grid that fits the box's CONTENT area, or nil when the box
    /// cannot be measured yet — zero cell metrics before the renderer has measured,
    /// an empty box while the board is hidden, or a NaN from a failed measurement.
    /// Nil means "propose nothing": resizing a live program's PTY to NaN or to the
    /// minimum grid would be far worse than leaving it alone.
    public static func propose(_ box: Box) -> Grid? {
        let positiveAndFinite = [box.boxHeight, box.boxWidth, box.cellWidth, box.cellHeight]
        guard positiveAndFinite.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        guard [box.paddingVertical, box.paddingHorizontal, box.scrollbarWidth].allSatisfy(\.isFinite) else { return nil }
        return Grid(
            cols: cellCount((box.boxWidth - box.paddingHorizontal - box.scrollbarWidth) / box.cellWidth, atLeast: minCols),
            rows: cellCount((box.boxHeight - box.paddingVertical) / box.cellHeight, atLeast: minRows)
        )
    }

    /// Whole cells, floored at `atLeast`; a finite quotient too large for `Int`
    /// saturates rather than trapping.
    private static func cellCount(_ quotient: CGFloat, atLeast floor: Int) -> Int {
        guard let cells = Int(exactly: quotient.rounded(.down)) else { return quotient > 0 ? .max : floor }
        return max(floor, cells)
    }
}
