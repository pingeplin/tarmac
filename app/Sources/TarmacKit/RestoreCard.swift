/// The card over the board after a first-visit restore with cold spawns
/// (backlog §1.2, issue #358): the restore's summary over a dimmed board, until
/// any key or a click closes it. Its keys are decided by `KeyLadder`.
public struct RestoreCard: Equatable, Sendable {
    public static let footer = "any key to continue"

    public let lines: [String]

    /// Nil when the summary has no line: a card that says nothing is not shown.
    public static func make(plan: BoardRestore.Plan) -> RestoreCard? {
        let lines = RestoreSummary.lines(plan: plan)
        return lines.isEmpty ? nil : RestoreCard(lines: lines)
    }
}
