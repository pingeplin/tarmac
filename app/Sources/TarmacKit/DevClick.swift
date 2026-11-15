import CoreGraphics

/// The controls `tarmac dev click` can name (spec 2611.0015 D16): a closed
/// set, owned by the app as it owns `key` combos. The CLI sends a name as it
/// is, so one definition decides which names exist.
public enum DevClick {
    /// A control as the model that draws it names it; `rawValue` is its wire
    /// name.
    public enum Control: Equatable, Sendable, RawRepresentable {
        /// A resume panel's button.
        case panel(ResumePanel.Choice)
        /// The header's `resume` chip.
        case resumeChip
        /// One of the restore card's choices.
        case restore(RestoreCard.Choice.Action)
        /// The restore card's veil, outside the card.
        case veil

        public var rawValue: String {
            switch self {
            case .panel(.resume): "resume"
            case .panel(.skip): "skip"
            case .resumeChip: "resume_chip"
            case .restore(.resumeAll): "resume_all"
            case .restore(.perCard): "decide_per_card"
            case .restore(.skipAll): "skip_all"
            case .veil: "veil"
            }
        }

        public init?(rawValue: String) {
            guard let control = (controls(of: .card) + controls(of: .restoreCard)).first(where: { $0.rawValue == rawValue })
            else { return nil }
            self = control
        }
    }

    public enum Target: Equatable, Sendable {
        case card
        /// `restore_card` on the command line: the absent `card` on the wire.
        case restoreCard
    }

    public static func controls(of target: Target) -> [Control] {
        switch target {
        case .card: [.panel(.resume), .panel(.skip), .resumeChip]
        case .restoreCard: [.restore(.resumeAll), .restore(.perCard), .restore(.skipAll), .veil]
        }
    }

    /// What a terminal card shows now, from the models that draw it: the
    /// panel's buttons, then the header chip.
    public static func present(panel: ResumePanel.Model?, chip: ResumeHeaderChip.Model?) -> [Control] {
        (panel?.buttons ?? []).map { .panel($0.choice) } + (chip == nil ? [] : [.resumeChip])
    }

    /// What the restore card shows now: its choices, then the veil, which
    /// every restore card has.
    public static func present(restoreChoices: [RestoreCard.Choice.Action]) -> [Control] {
        restoreChoices.map(Control.restore) + [.veil]
    }

    /// The veil's candidate points: those of the overlay outside the card,
    /// where a user's click is "decide per card".
    public static func veilPoints(in bounds: CGRect, card: CGRect) -> [CGPoint] {
        DevTargetPoints.candidates(in: bounds).filter { !card.contains($0) }
    }

    /// `click`'s reply, read after the UI settled: what the click was, and the
    /// two facts a click on `resume` changes. The caller reads the rest with
    /// `snapshot`.
    public static func reply(
        card: String?, control: Control, selectedCard: String?, keyboardFocus: DevSnapshot.KeyboardFocus
    ) -> JSONValue {
        guard case .object(var fields) = DevSnapshot.focusReply(selectedCard: selectedCard, keyboardFocus: keyboardFocus)
        else { return .null }
        fields["card"] = card.map(JSONValue.string) ?? .null
        fields["control"] = .string(control.rawValue)
        return .object(fields)
    }
}
