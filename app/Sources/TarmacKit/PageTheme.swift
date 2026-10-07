/// What a loaded page was last given for its colours (spec 2610.0008).
public struct PageTheme: Equatable, Sendable {
    private var palette: Palette

    /// A page loaded with `palette` in its template.
    public init(_ palette: Palette) {
        self.palette = palette
    }

    /// Whether `palette` differs from what the page has. When it does, the
    /// page has it from now on.
    public mutating func take(_ palette: Palette) -> Bool {
        guard palette != self.palette else { return false }
        self.palette = palette
        return true
    }
}
