/// Tiny pure formatters for the chrome overlays: the zoom-control percent
/// readout, the titlebar-chip label fallback and the on-card recency meta.
public enum ChromeText {
    /// How long after a change a doc card still says so.
    public static let recentWindowMs: UInt64 = 30_000

    /// Zoom readout, e.g. 1 → "100%", 0.125 → "13%". Written as `Math.round` and
    /// `String(number)` did, so a NaN, an infinity or a huge zoom reads "NaN%",
    /// "Infinity%" or in full rather than trapping an integer conversion.
    public static func zoomPercent(_ zoom: Double) -> String {
        "\((zoom * 100).roundedHalfUp.javaScriptString)%"
    }

    /// The board's display name, falling back to its id when the name is absent
    /// OR empty, so an empty name never renders a blank chip.
    public static func boardChipLabel(name: String?, boardID: String) -> String {
        guard let name, !name.isEmpty else { return boardID }
        return name
    }

    /// The status bar's count of the cards on the active board.
    public static func cardCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "card" : "cards")"
    }

    /// The on-card recency meta `✎ Ns`, or nil when the doc has no change time or
    /// the last change is at or past the window. A future-dated change time
    /// (mtime/clock skew) counts as recent and clamps the elapsed time to zero.
    /// Seconds are floored at 1.
    public static func recencyLabel(lastChangedMs: UInt64?, nowMs: UInt64) -> String? {
        guard let changed = lastChangedMs,
              nowMs < changed || nowMs - changed < recentWindowMs
        else { return nil }
        let elapsedMs = nowMs > changed ? nowMs - changed : 0
        return "✎ \(max(1, Int((Double(elapsedMs) / 1000).rounded())))s"
    }
}
