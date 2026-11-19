import CoreGraphics

/// Overlay-level offscreen-hint logic: the single ⏎-fly target, the pill
/// label, which pills are shown, and the per-edge greedy stacking layout. The edge geometry itself
/// (`BoardWayfinding.hintPlacement`, `Edge.arrow`) lives in `BoardWayfinding`;
/// this adds what lived in the untested AppKit overlay. Pure and clock-free — the
/// view supplies the measured pill sizes, the HH:MM text and each signal's time.
public enum OffscreenHintLayout {
    /// One signalling card, in VIEW (overlay-local) coordinates.
    public struct Hint: Equatable, Sendable {
        public var cardID: String
        public var centerView: CGPoint
        public var signal: CardSignal
        public var label: InlineText
        /// Stacking order; higher is more recently fronted. Breaks a tie of rank.
        public var z: Int
        /// When the signal came, in ms since the epoch; nil for live.
        public var signalAt: UInt64?

        public init(
            cardID: String, centerView: CGPoint, signal: CardSignal, label: InlineText, z: Int, signalAt: UInt64?
        ) {
            self.cardID = cardID
            self.centerView = centerView
            self.signal = signal
            self.label = label
            self.z = z
            self.signalAt = signalAt
        }
    }

    /// The single ⏎-fly target: the hint with the highest `(rank, z)`, or nil
    /// when empty. The first wins a tie (strictly-greater swap), so callers
    /// must iterate cards in a stable order for determinism.
    static func flyTarget(_ hints: [Hint]) -> String? {
        var best: Hint?
        for hint in hints {
            guard let current = best else {
                best = hint
                continue
            }
            if (hint.signal.rank, hint.z) > (current.signal.rank, current.z) { best = hint }
        }
        return best?.cardID
    }

    /// The most pills the board shows at once (#373); the inbox lists the rest.
    public static let maxPills = 10

    /// The hints that get a pill, in their input order: at most `maxPills`,
    /// by rank, then the newest signal (live has none), then the higher z,
    /// then the earlier hint.
    static func shown(_ hints: [Hint]) -> [Hint] {
        guard hints.count > maxPills else { return hints }
        let keys = hints.indices.map { (hints[$0].signal.rank, hints[$0].signalAt ?? 0, hints[$0].z, -$0) }
        return hints.indices.sorted { keys[$0] > keys[$1] }.prefix(maxPills).sorted().map { hints[$0] }
    }

    /// The pills to show, and the ⏎-fly target, taken from every hint whose
    /// centre is outside `viewRect`: the target can be a card the cap left
    /// without a pill.
    public static func select(_ hints: [Hint], in viewRect: CGRect) -> (shown: [Hint], flyTarget: String?) {
        let offscreen = hints.filter { !viewRect.contains($0.centerView) }
        return (shown(offscreen), flyTarget(offscreen))
    }

    /// The time of the card's shown signal: a report's for blocked and done,
    /// the bell's, the exit's; live has none.
    public static func signalAt(
        _ signal: CardSignal, reportAtMs: UInt64?, bellAtMs: UInt64?, exitAtMs: UInt64?
    ) -> UInt64? {
        switch signal {
        case .blocked, .done: reportAtMs
        case .bell: bellAtMs
        case .exit: exitAtMs
        case .live: nil
        }
    }

    /// The longest start of a report's text a pill quotes, in Unicode scalars.
    public static let quoteScalars = 24

    /// A bell reads `name · hhmm` (middle dot U+00B7); a report quotes the
    /// start of its text as one line of inline markdown, cut by rendered
    /// scalars (spec 2611.0017); an exit says so; live reads the name. Only
    /// the quote is parsed.
    public static func pillLabel(signal: CardSignal, name: String, hhmm: String, quote: String?) -> InlineText {
        switch signal {
        case .blocked, .done:
            guard let quote else { return .literal("\(name) · report") }
            return .literal("\(name) · ") + InlineMarkdown.line(quote).prefix(scalars: quoteScalars).quoted
        case .bell: return .literal("\(name) · \(hhmm)")
        case .exit: return .literal("\(name) · exited")
        case .live: return .literal(name)
        }
    }
}
