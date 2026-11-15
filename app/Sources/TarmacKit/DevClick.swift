import CoreGraphics

/// The controls `tarmac dev click` can name (spec 2611.0015 D16): a closed
/// set, owned by the app as it owns `key` combos. The CLI sends a name as it
/// is, so one definition decides which names exist.
public enum DevClick {
    public enum Control: String, CaseIterable, Sendable {
        case resume, skip, resumeChip = "resume_chip"
        case resumeAll = "resume_all", decidePerCard = "decide_per_card", skipAll = "skip_all", veil
    }

    public enum Target: Equatable, Sendable {
        case card
        /// `restore_card` on the command line: the absent `card` on the wire.
        case restoreCard
    }

    public static func controls(of target: Target) -> [Control] {
        switch target {
        case .card: [.resume, .skip, .resumeChip]
        case .restoreCard: [.resumeAll, .decidePerCard, .skipAll, .veil]
        }
    }

    /// What a terminal card shows now, from the models that draw it: the
    /// panel's buttons, then the header chip.
    public static func present(panel: ResumePanel.Model?, chip: ResumeHeaderChip.Model?) -> [Control] {
        let buttons: [Control] = (panel?.buttons ?? []).map { button in
            switch button.choice {
            case .resume: .resume
            case .skip: .skip
            }
        }
        return buttons + (chip == nil ? [] : [.resumeChip])
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
