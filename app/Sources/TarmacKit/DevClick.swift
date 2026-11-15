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
}
