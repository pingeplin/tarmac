/// What a terminal card tells the daemon about its cols×rows.
public enum TermGrid {
    public struct Size: Equatable, Sendable {
        public var cols: Int
        public var rows: Int

        public init(cols: Int, rows: Int) {
            self.cols = cols
            self.rows = rows
        }
    }

    /// The grid a cold spawn asks for: what the card measured, never below 2×2.
    public static func spawn(cols: Int, rows: Int) -> Size {
        Size(cols: max(2, cols), rows: max(2, rows))
    }

    /// The resize to send for a new measurement, or nil. A card that is not on
    /// screen — its board is in the background — or that measures no cells
    /// proposes nothing: shrinking a running program's PTY to a degenerate grid
    /// is the failure this guards against. `lastSent` is nil until the terminal
    /// has told the daemon a size.
    public static func resize(_ measured: Size, onScreen: Bool, lastSent: Size?) -> Size? {
        guard onScreen, measured.cols >= 1, measured.rows >= 1, measured != lastSent else { return nil }
        return measured
    }
}
