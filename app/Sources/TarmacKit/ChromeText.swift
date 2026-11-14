/// Tiny pure formatters for the chrome overlays: the zoom-control percent
/// readout, the status bar's card count, the on-card recency meta and a
/// terminal report's age.
public enum ChromeText {
    /// How long after a change a doc card still says so.
    public static let recentWindowMs: UInt64 = 30_000

    /// Zoom readout, e.g. 1 → "100%", 0.125 → "13%". Written as `Math.round` and
    /// `String(number)` did, so a NaN, an infinity or a huge zoom reads "NaN%",
    /// "Infinity%" or in full rather than trapping an integer conversion.
    public static func zoomPercent(_ zoom: Double) -> String {
        "\((zoom * 100).roundedHalfUp.javaScriptString)%"
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

    /// A terminal report's age (spec 2611.0009): `<1m`, `Nm`, `Nh` or `Nd`,
    /// each floored.
    public static func reportAge(elapsedMs: UInt64) -> String {
        let minutes = elapsedMs / 60_000
        switch minutes {
        case 0: return "<1m"
        case ..<60: return "\(minutes)m"
        case ..<(24 * 60): return "\(minutes / 60)h"
        default: return "\(minutes / (24 * 60))d"
        }
    }
}
